//! `layover saver`: one overlay layer surface per output, drawn by the
//! renderer, until any input or SIGTERM. The daemon starts it; `layover
//! saver --hack <id> --for 20s` previews one hack by hand.

use anyhow::{Context, Result, anyhow, bail};
use layover_core::config::Config;
use layover_core::feeds::{self, LineUpdate, Row};
use layover_hacks::Hack;
use layover_hacks::board::{BoardData, DATA_ROWS};
use layover_hacks::gpu::{self, Gpu};
use layover_hacks::renderer::{CareSettings, Frame, Placement, Renderer};
use raw_window_handle::{
    RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle,
};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState, FrameCallbackData},
    delegate_registry,
    dispatch2::Dispatch2,
    output::{OutputHandler, OutputState},
    reexports::{
        calloop::{
            EventLoop,
            channel::{self as cchannel, Event as ChannelEvent},
        },
        calloop_wayland_source::WaylandSource,
    },
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        Capability, SeatHandler, SeatState,
        pointer::{PointerEvent, PointerEventKind, PointerHandler},
    },
    shell::{
        WaylandSurface,
        wlr_layer::{
            Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
            LayerSurfaceConfigure,
        },
    },
};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::ptr::NonNull;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wayland_client::{
    Connection, Proxy, QueueHandle,
    globals::registry_queue_init,
    protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_surface},
};

/// How long input is ignored after the saver starts, so the key or click
/// that launched a preview doesn't end it.
const GRACE: Duration = Duration::from_millis(1200);
/// Pointer travel that counts as someone at the desk, in surface pixels.
const NUDGE: f64 = 12.0;
/// How long startup waits for every output's initial layer configure before
/// beginning to draw with whichever outputs are ready.
const STARTUP_GRACE: Duration = Duration::from_millis(200);
/// Early wake slack so small epoll/timer jitter before a vblank window doesn't
/// cost an extra event-loop sleep.
const WAKE_TOLERANCE: Duration = Duration::from_micros(500);
/// Minimum time before a missing `wl_surface.frame` callback marks an output
/// as stalled.
const MIN_WATCHDOG: Duration = Duration::from_millis(150);
/// Upper bound on event-loop dispatch timeout so run_for limits and external
/// events stay responsive.
const MAX_DISPATCH_WAIT: Duration = Duration::from_millis(100);

pub struct Options {
    pub hacks: Vec<&'static Hack>,
    pub run_for: Option<Duration>,
}

struct Out {
    // Declared first so it drops before the layer surface it draws on.
    gpu_surface: Option<wgpu::Surface<'static>>,
    layer: LayerSurface,
    output: wl_output::WlOutput,
    /// x, y, width, height in logical pixels on the desktop.
    logical: [i32; 4],
    scale: i32,
    format: Option<wgpu::TextureFormat>,
    px: [u32; 2],
}

#[derive(Clone, Debug, Default)]
struct OutputSlot {
    configured: bool,
    refresh_mhz: Option<u32>,
    frame_pending: bool,
    last_vblank: Option<Instant>,
    stalled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum PacerState {
    WaitingStartup { deadline: Instant },
    WaitingVblank { presented_at: Instant, watchdog: Instant },
    WaitingCadence { next_draw: Instant, min_vblank: Instant, max_vblank: Instant },
    FixedFallback { next_draw: Instant },
}

#[derive(Clone, Debug)]
struct Pacer {
    state: PacerState,
}

fn target_interval(target_fps: u32) -> Duration {
    Duration::from_secs_f64(1.0 / target_fps.max(1) as f64)
}

fn vblank_stride(refresh_hz: f64, target_fps: u32) -> u32 {
    if !refresh_hz.is_finite() || refresh_hz <= 0.0 {
        return 1;
    }
    let ratio = refresh_hz / target_fps.max(1) as f64;
    // 2% clock tolerance so e.g. 60.02 Hz @ 30 fps -> stride 2,
    // 59.951 Hz @ 30 fps -> stride 2, 59.951 Hz @ 60 fps -> stride 1,
    // 144 Hz @ 30 fps -> stride 5 (never overshoots target_fps).
    if ratio <= 1.02 {
        1
    } else if ratio - ratio.floor() <= 0.02 {
        ratio.floor() as u32
    } else {
        ratio.ceil() as u32
    }
}

fn compute_vblank_deadline(
    min_vblank: Instant,
    max_vblank: Instant,
    refresh_hz: f64,
    target_fps: u32,
) -> Instant {
    let vblank = Duration::from_secs_f64(1.0 / refresh_hz);
    let stride = vblank_stride(refresh_hz, target_fps);
    if stride <= 1 {
        return max_vblank;
    }
    let spread = max_vblank.saturating_duration_since(min_vblank);
    if spread < vblank.mul_f64(0.75) {
        let window_start = max_vblank + vblank * (stride - 1);
        let window_end = min_vblank + vblank * stride;
        let width = window_end.saturating_duration_since(window_start);
        window_start + width.mul_f64(0.25)
    } else {
        // Outputs drifted by roughly a full vblank or more; anchor past the
        // latest callback so they latch onto the next shared vblank together.
        max_vblank + vblank * (stride - 1) + vblank.mul_f64(0.25)
    }
}

fn advance_fixed_deadline(prev: Instant, interval: Duration, now: Instant) -> Instant {
    let mut next = prev + interval;
    if next <= now {
        let elapsed = now.saturating_duration_since(prev);
        let steps = (elapsed.as_nanos() / interval.as_nanos().max(1)) + 1;
        let steps_u32 = u32::try_from(steps).unwrap_or(u32::MAX);
        next = prev.checked_add(interval.saturating_mul(steps_u32)).unwrap_or(now + interval);
        while next <= now {
            next += interval;
        }
    }
    next
}

fn watchdog_duration(interval: Duration) -> Duration {
    (interval * 2).max(MIN_WATCHDOG)
}

impl Pacer {
    fn new(started: Instant) -> Self {
        Pacer { state: PacerState::WaitingStartup { deadline: started + STARTUP_GRACE } }
    }

    fn reference_refresh_hz(slots: &[OutputSlot]) -> Option<f64> {
        let active = slots
            .iter()
            .filter(|s| s.configured && !s.stalled)
            .filter_map(|s| s.refresh_mhz)
            .filter(|&r| r > 0)
            .min();
        let mhz = active.or_else(|| {
            slots
                .iter()
                .filter(|s| s.configured)
                .filter_map(|s| s.refresh_mhz)
                .filter(|&r| r > 0)
                .min()
        })?;
        Some(mhz as f64 / 1000.0)
    }

    fn resolve_vblank_barrier(
        &mut self,
        slots: &[OutputSlot],
        presented_at: Instant,
        target_fps: u32,
        now: Instant,
    ) {
        let mut min_vblank: Option<Instant> = None;
        let mut max_vblank: Option<Instant> = None;
        for slot in slots {
            if !slot.configured || slot.stalled {
                continue;
            }
            if let Some(vb) = slot.last_vblank
                && vb >= presented_at
            {
                min_vblank = Some(min_vblank.map_or(vb, |m| m.min(vb)));
                max_vblank = Some(max_vblank.map_or(vb, |m| m.max(vb)));
            }
        }
        if let (Some(min_vb), Some(max_vb), Some(hz)) =
            (min_vblank, max_vblank, Self::reference_refresh_hz(slots))
        {
            self.state = PacerState::WaitingCadence {
                next_draw: compute_vblank_deadline(min_vb, max_vb, hz, target_fps),
                min_vblank: min_vb,
                max_vblank: max_vb,
            };
        } else {
            self.state = PacerState::FixedFallback {
                next_draw: advance_fixed_deadline(presented_at, target_interval(target_fps), now),
            };
        }
    }

    fn on_frame_barrier(&mut self, slots: &[OutputSlot], target_fps: u32, now: Instant) {
        let PacerState::WaitingVblank { presented_at, .. } = self.state else { return };
        if slots.iter().any(|s| s.configured && !s.stalled && s.frame_pending) {
            return;
        }
        self.resolve_vblank_barrier(slots, presented_at, target_fps, now);
    }

    fn recompute_cadence(&mut self, slots: &[OutputSlot], target_fps: u32) {
        if let PacerState::WaitingCadence { next_draw, min_vblank, max_vblank } = &mut self.state
            && let Some(hz) = Self::reference_refresh_hz(slots)
        {
            *next_draw = compute_vblank_deadline(*min_vblank, *max_vblank, hz, target_fps);
        }
    }

    fn on_presented(
        &mut self,
        slots: &[OutputSlot],
        presented_count: usize,
        target_fps: u32,
        now: Instant,
    ) {
        let prev_anchor = match self.state {
            PacerState::FixedFallback { next_draw } => next_draw,
            _ => now,
        };
        let interval = target_interval(target_fps);
        if presented_count == 0 {
            self.state = PacerState::FixedFallback {
                next_draw: advance_fixed_deadline(prev_anchor, interval, now),
            };
        } else if slots.iter().any(|s| s.configured && !s.stalled && s.frame_pending) {
            self.state = PacerState::WaitingVblank {
                presented_at: now,
                watchdog: now + watchdog_duration(interval),
            };
        } else {
            self.state = PacerState::FixedFallback {
                next_draw: advance_fixed_deadline(prev_anchor, interval, now),
            };
        }
    }

    fn should_draw(&mut self, slots: &mut [OutputSlot], target_fps: u32, now: Instant) -> bool {
        match self.state {
            PacerState::WaitingStartup { deadline } => {
                (!slots.is_empty() && slots.iter().all(|s| s.configured))
                    || (now >= deadline && slots.iter().any(|s| s.configured))
            }
            PacerState::WaitingVblank { presented_at, watchdog } => {
                if now < watchdog {
                    return false;
                }
                for slot in slots.iter_mut() {
                    if slot.configured && slot.frame_pending {
                        slot.stalled = true;
                        slot.frame_pending = false;
                    }
                }
                self.resolve_vblank_barrier(slots, presented_at, target_fps, now);
                match self.state {
                    PacerState::WaitingCadence { next_draw, .. } => {
                        now + WAKE_TOLERANCE >= next_draw
                    }
                    PacerState::FixedFallback { .. } => true,
                    PacerState::WaitingStartup { .. } | PacerState::WaitingVblank { .. } => false,
                }
            }
            PacerState::WaitingCadence { next_draw, .. }
            | PacerState::FixedFallback { next_draw } => now + WAKE_TOLERANCE >= next_draw,
        }
    }

    fn next_wait(&self, now: Instant) -> Duration {
        let target = match self.state {
            PacerState::WaitingStartup { deadline } => deadline,
            PacerState::WaitingVblank { watchdog, .. } => watchdog,
            PacerState::WaitingCadence { next_draw, .. }
            | PacerState::FixedFallback { next_draw } => next_draw,
        };
        target.saturating_duration_since(now).max(Duration::from_millis(1))
    }
}

struct Saver {
    registry: RegistryState,
    seats: SeatState,
    outputs_state: OutputState,
    conn: Connection,
    qh: QueueHandle<Saver>,
    instance: wgpu::Instance,
    gpu: Option<Gpu>,
    renderer: Option<Renderer>,
    outs: Vec<Out>,
    pace: Vec<OutputSlot>,
    pacer: Pacer,
    canvas: [f32; 2],
    origin: [i32; 2],
    care: CareSettings,
    cfg: Config,
    hacks: Vec<&'static Hack>,
    started: Instant,
    last_frame: Instant,
    t_offset: f32,
    seed: f32,
    pointer: Option<wl_pointer::WlPointer>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer_from: Option<(f64, f64)>,
    exit: Option<&'static str>,
    failed: Option<anyhow::Error>,
    /// The line's rows with when each last changed (`HH:MM`, hack seconds).
    rows: Vec<(Row, String, f32)>,
    clock: String,
    header_changed: f32,
    board_dirty: bool,
    /// Cheap mode, from the daemon: half rate, half size, dimmer.
    cheap: bool,
}

fn noise_seed() -> u64 {
    let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    n.as_nanos() as u64 ^ (std::process::id() as u64).rotate_left(32)
}

pub fn run(cfg: &Config, opts: Options) -> Result<()> {
    if opts.hacks.is_empty() {
        bail!("no hacks to show");
    }
    let conn =
        Connection::connect_to_env().context("no Wayland display (is WAYLAND_DISPLAY set?)")?;
    let (globals, mut queue) =
        registry_queue_init::<Saver>(&conn).context("reading Wayland globals")?;
    let qh = queue.handle();
    let compositor =
        CompositorState::bind(&globals, &qh).context("the compositor has no wl_compositor")?;
    let layer_shell =
        LayerShell::bind(&globals, &qh).context("the compositor has no wlr-layer-shell")?;

    let seed = noise_seed();
    let started = Instant::now();
    let mut state = Saver {
        registry: RegistryState::new(&globals),
        seats: SeatState::new(&globals, &qh),
        outputs_state: OutputState::new(&globals, &qh),
        conn: conn.clone(),
        qh: qh.clone(),
        instance: gpu::instance(),
        gpu: None,
        renderer: None,
        outs: Vec::new(),
        pace: Vec::new(),
        pacer: Pacer::new(started),
        canvas: [1.0, 1.0],
        origin: [0, 0],
        care: CareSettings::from_config(&cfg.care),
        cfg: cfg.clone(),
        hacks: opts.hacks,
        started,
        last_frame: started,
        t_offset: (seed % 100_000) as f32 / 100.0,
        seed: ((seed >> 20) % 1000) as f32 / 1000.0,
        pointer: None,
        keyboard: None,
        pointer_from: None,
        exit: None,
        failed: None,
        rows: Vec::new(),
        clock: String::new(),
        header_changed: 0.0,
        board_dirty: true,
        cheap: false,
    };
    // Learn the outputs and where they sit.
    queue.roundtrip(&mut state).context("talking to the compositor")?;
    queue.roundtrip(&mut state).context("talking to the compositor")?;

    let outputs: Vec<_> = state.outputs_state.outputs().collect();
    if outputs.is_empty() {
        bail!("the compositor reports no outputs");
    }
    for output in outputs {
        let Some(info) = state.outputs_state.info(&output) else { continue };
        let pos = info.logical_position.unwrap_or(info.location);
        let size = info.logical_size.unwrap_or_else(|| {
            let m =
                info.modes.iter().find(|m| m.current).map(|m| m.dimensions).unwrap_or((1920, 1080));
            (m.0 / info.scale_factor.max(1), m.1 / info.scale_factor.max(1))
        });
        let refresh_mhz = info
            .modes
            .iter()
            .find(|m| m.current)
            .map(|m| m.refresh_rate)
            .filter(|&r| r > 0)
            .map(|r| r as u32);
        let surface = compositor.create_surface(&qh);
        let layer = layer_shell.create_layer_surface(
            &qh,
            surface,
            Layer::Overlay,
            Some("layover"),
            Some(&output),
        );
        layer.set_anchor(Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT);
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
        layer.set_size(0, 0);
        layer.wl_surface().set_buffer_scale(info.scale_factor.max(1));
        layer.commit();
        state.outs.push(Out {
            gpu_surface: None,
            layer,
            output,
            logical: [pos.0, pos.1, size.0, size.1],
            scale: info.scale_factor.max(1),
            format: None,
            px: [0, 0],
        });
        state.pace.push(OutputSlot { refresh_mhz, ..Default::default() });
    }
    state.layout_canvas();

    let mut event_loop: EventLoop<Saver> =
        EventLoop::try_new().context("creating the event loop")?;
    WaylandSource::new(conn, queue)
        .insert(event_loop.handle())
        .map_err(|e| anyhow!("watching the Wayland socket: {e}"))?;
    let (line_tx, line_rx) = cchannel::channel::<LineUpdate>();
    subscribe_line(line_tx);
    event_loop
        .handle()
        .insert_source(line_rx, |ev, _, s: &mut Saver| {
            if let ChannelEvent::Msg(update) = ev {
                s.take_line(update);
            }
        })
        .map_err(|e| anyhow!("watching the line: {e}"))?;

    while state.exit.is_none() && state.failed.is_none() {
        let now = Instant::now();
        if let Some(limit) = opts.run_for
            && now.saturating_duration_since(state.started) >= limit
        {
            state.exit = Some("time is up");
            break;
        }
        if state.should_draw(now) {
            state.draw(now);
            if state.exit.is_some() || state.failed.is_some() {
                break;
            }
        }
        let now = Instant::now();
        let mut timeout = state.pacer.next_wait(now).min(MAX_DISPATCH_WAIT);
        if let Some(limit) = opts.run_for {
            let remaining = limit.saturating_sub(now.saturating_duration_since(state.started));
            timeout = if remaining.is_zero() {
                Duration::ZERO
            } else {
                timeout.min(remaining.max(Duration::from_millis(1)))
            };
        }
        event_loop.dispatch(Some(timeout), &mut state).context("dispatching Wayland events")?;
    }
    if let Some(err) = state.failed.take() {
        return Err(err);
    }
    // Drop GPU surfaces before their layer surfaces.
    for o in &mut state.outs {
        o.gpu_surface = None;
    }
    Ok(())
}

/// Ask the daemon for the line: the board's rows and cheap mode, now and on
/// every change. Without a daemon the board says nothing is on the line.
fn subscribe_line(tx: cchannel::Sender<LineUpdate>) {
    std::thread::spawn(move || {
        let Ok(mut s) = UnixStream::connect(layover_core::paths::socket()) else { return };
        if writeln!(s, r#"{{"cmd":"line"}}"#).is_err() {
            return;
        }
        for line in BufReader::new(s).lines() {
            let Ok(line) = line else { return };
            if let Ok(update) = serde_json::from_str::<LineUpdate>(&line)
                && tx.send(update).is_err()
            {
                return;
            }
        }
    });
}

fn clock_now() -> String {
    let unix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    crate::log::clock_at(unix).chars().take(5).collect()
}

impl Saver {
    fn target_fps(&self) -> u32 {
        let div = if self.cheap { feeds::CHEAP_FPS_DIVISOR } else { 1 };
        (self.cfg.power.effective_fps() / div).max(1)
    }

    fn should_draw(&mut self, now: Instant) -> bool {
        let fps = self.target_fps();
        self.pacer.should_draw(&mut self.pace, fps, now)
    }

    fn hack_time(&self) -> f32 {
        self.t_offset + self.started.elapsed().as_secs_f32()
    }

    fn offscreen_size(&self) -> [u32; 2] {
        let cheap = if self.cheap { feeds::CHEAP_SCALE } else { 1.0 };
        let scale = self.outs.iter().map(|o| o.scale).max().unwrap_or(1) as f32
            * self.cfg.power.effective_scale()
            * cheap;
        [(self.canvas[0] * scale).round() as u32, (self.canvas[1] * scale).round() as u32]
    }

    /// The line changed: note which rows did, and switch cheap mode.
    fn take_line(&mut self, update: LineUpdate) {
        let t = self.hack_time();
        let now = clock_now();
        let rows = update
            .rows
            .into_iter()
            .take(DATA_ROWS)
            .map(|r| match self.rows.iter().find(|(p, _, _)| p.from == r.from) {
                Some((p, at, changed)) if *p == r => (r, at.clone(), *changed),
                _ => (r, now.clone(), t),
            })
            .collect();
        self.rows = rows;
        self.board_dirty = true;
        if update.cheap != self.cheap {
            self.cheap = update.cheap;
            eprintln!("layover saver: {}", if self.cheap { "cheap mode" } else { "full rate" });
            self.apply_cheap();
            self.pacer.recompute_cadence(&self.pace, self.target_fps());
        }
    }

    fn apply_cheap(&mut self) {
        let size = self.offscreen_size();
        let canvas = self.canvas;
        if let Some(r) = self.renderer.as_mut() {
            r.set_dim(if self.cheap { feeds::CHEAP_DIM } else { 1.0 });
            r.resize(canvas, size);
        }
    }

    /// Upload the board when a row or the clock changed.
    fn refresh_board(&mut self) {
        let now = clock_now();
        if now != self.clock {
            self.clock = now;
            self.header_changed = self.hack_time();
            self.board_dirty = true;
        }
        if !self.board_dirty {
            return;
        }
        let Some(r) = self.renderer.as_ref() else { return };
        let rows: Vec<Row> = self.rows.iter().map(|(r, _, _)| r.clone()).collect();
        let times: Vec<String> = self.rows.iter().map(|(_, at, _)| at.clone()).collect();
        let mut changed = vec![self.header_changed];
        changed.extend(self.rows.iter().map(|(_, _, t)| *t));
        r.set_board(&BoardData::compose(&rows, &times, &self.clock, &changed));
        self.board_dirty = false;
    }

    fn layout_canvas(&mut self) {
        let min_x = self.outs.iter().map(|o| o.logical[0]).min().unwrap_or(0);
        let min_y = self.outs.iter().map(|o| o.logical[1]).min().unwrap_or(0);
        let max_x = self.outs.iter().map(|o| o.logical[0] + o.logical[2]).max().unwrap_or(1);
        let max_y = self.outs.iter().map(|o| o.logical[1] + o.logical[3]).max().unwrap_or(1);
        self.origin = [min_x, min_y];
        self.canvas = [(max_x - min_x).max(1) as f32, (max_y - min_y).max(1) as f32];
    }

    fn ensure_gpu(&mut self, idx: usize) -> Result<()> {
        if self.outs[idx].gpu_surface.is_none() {
            let display = RawDisplayHandle::Wayland(WaylandDisplayHandle::new(
                NonNull::new(self.conn.backend().display_ptr() as *mut _)
                    .ok_or_else(|| anyhow!("no display pointer"))?,
            ));
            let window = RawWindowHandle::Wayland(WaylandWindowHandle::new(
                NonNull::new(self.outs[idx].layer.wl_surface().id().as_ptr() as *mut _)
                    .ok_or_else(|| anyhow!("no surface pointer"))?,
            ));
            // SAFETY: the display outlives the saver, and the wgpu surface is
            // dropped before its layer surface (field order and `run`'s end).
            let surface = unsafe {
                self.instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: Some(display),
                    raw_window_handle: window,
                })
            }
            .context("creating a GPU surface")?;
            self.outs[idx].gpu_surface = Some(surface);
        }
        if self.gpu.is_none() {
            let gpu =
                Gpu::new(&self.instance, self.cfg.power.gpu, self.outs[idx].gpu_surface.as_ref())?;
            eprintln!("layover saver: drawing on {}", gpu.describe());
            let mut renderer = Renderer::new(&gpu.device, &gpu.queue, self.care.clone());
            renderer.resize(self.canvas, self.offscreen_size());
            renderer.set_dim(if self.cheap { feeds::CHEAP_DIM } else { 1.0 });
            renderer.set_antialias(self.cfg.saver.antialias);
            renderer.reset_limiter();
            renderer.reset_state();
            for hack in &self.hacks {
                renderer.prepare(hack)?;
            }
            self.renderer = Some(renderer);
            self.gpu = Some(gpu);
            self.board_dirty = true;
        }
        Ok(())
    }

    fn configure_output(&mut self, idx: usize, w: u32, h: u32) -> Result<()> {
        self.ensure_gpu(idx)?;
        let gpu = self.gpu.as_ref().expect("gpu is ready");
        let out = &mut self.outs[idx];
        let surface = out.gpu_surface.as_ref().expect("surface is ready");
        let caps = surface.get_capabilities(&gpu.adapter);
        // Plain (not sRGB) formats: the care pass writes drive levels, and
        // the panel should get them as written.
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| !f.is_srgb())
            .or_else(|| caps.formats.first().copied())
            .ok_or_else(|| anyhow!("the GPU can't present to this output"))?;
        let alpha = if caps.alpha_modes.contains(&wgpu::CompositeAlphaMode::Opaque) {
            wgpu::CompositeAlphaMode::Opaque
        } else {
            caps.alpha_modes[0]
        };
        let present_mode = if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) {
            wgpu::PresentMode::Mailbox
        } else {
            wgpu::PresentMode::Fifo
        };
        let px = [w * out.scale as u32, h * out.scale as u32];
        surface.configure(
            &gpu.device,
            &wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format,
                view_formats: vec![],
                alpha_mode: alpha,
                width: px[0].max(1),
                height: px[1].max(1),
                desired_maximum_frame_latency: 2,
                present_mode,
                color_space: wgpu::SurfaceColorSpace::Auto,
            },
        );
        out.format = Some(format);
        out.px = px;
        self.pace[idx].configured = true;
        Ok(())
    }

    fn draw(&mut self, now: Instant) {
        if self.exit.is_some() || self.failed.is_some() || self.renderer.is_none() {
            return;
        }
        let dt = now.duration_since(self.last_frame).as_secs_f32().min(1.0);
        self.last_frame = now;
        let elapsed = now.duration_since(self.started).as_secs_f32();
        let (hack, fade) = layover_hacks::showing(&self.hacks, &self.cfg.care, elapsed);
        if hack.board {
            self.refresh_board();
        }
        let phase = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64()
            % 86_400.0;
        let frame = Frame { hack, t: self.t_offset + elapsed, phase, dt, seed: self.seed };
        match self.draw_frame(&frame, fade) {
            Ok(presented) => {
                let fps = self.target_fps();
                self.pacer.on_presented(&self.pace, presented, fps, Instant::now());
            }
            Err(e) => self.failed = Some(e),
        }
    }

    fn draw_frame(&mut self, frame: &Frame, fade: f32) -> Result<usize> {
        let gpu = self.gpu.as_ref().expect("gpu is ready");
        let renderer = self.renderer.as_mut().expect("renderer is ready");
        let mut enc = gpu.device.create_command_encoder(&Default::default());
        renderer.draw_canvas(&mut enc, frame)?;
        let mut frames = Vec::with_capacity(self.outs.len());
        for (i, out) in self.outs.iter().enumerate() {
            let (Some(surface), Some(format)) = (&out.gpu_surface, out.format) else { continue };
            let texture = match surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(t)
                | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
                other => {
                    eprintln!("layover saver: skipping a frame on an output: {other:?}");
                    continue;
                }
            };
            let view = texture.texture.create_view(&Default::default());
            let place = Placement {
                rect: [
                    (out.logical[0] - self.origin[0]) as f32,
                    (out.logical[1] - self.origin[1]) as f32,
                    out.logical[2] as f32,
                    out.logical[3] as f32,
                ],
                px: out.px,
            };
            renderer.draw_output(&mut enc, i, &view, format, &place, fade)?;
            frames.push((i, texture));
        }
        gpu.queue.submit(Some(enc.finish()));
        let presented = frames.len();
        for (idx, f) in frames {
            let surface = self.outs[idx].layer.wl_surface();
            surface.frame(&self.qh, FrameCallbackData(surface.clone()));
            self.pace[idx].frame_pending = true;
            gpu.queue.present(f);
        }
        let _ = self.conn.flush();
        Ok(presented)
    }

    fn wake(&mut self, why: &'static str) {
        if self.started.elapsed() >= GRACE && self.exit.is_none() {
            self.exit = Some(why);
        }
    }
}

impl CompositorHandler for Saver {
    fn scale_factor_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: i32,
    ) {
    }
    fn transform_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: wl_output::Transform,
    ) {
    }
    fn frame(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        surface: &wl_surface::WlSurface,
        _: u32,
    ) {
        let Some(idx) = self.outs.iter().position(|o| o.layer.wl_surface() == surface) else {
            return;
        };
        let now = Instant::now();
        self.pace[idx].frame_pending = false;
        self.pace[idx].stalled = false;
        self.pace[idx].last_vblank = Some(now);
        let fps = self.target_fps();
        self.pacer.on_frame_barrier(&self.pace, fps, now);
    }
    fn surface_enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
    fn surface_leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for Saver {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.outputs_state
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        let Some(idx) = self.outs.iter().position(|o| o.output == output) else { return };
        if let Some(info) = self.outputs_state.info(&output) {
            self.pace[idx].refresh_mhz = info
                .modes
                .iter()
                .find(|m| m.current)
                .map(|m| m.refresh_rate)
                .filter(|&r| r > 0)
                .map(|r| r as u32);
            self.pacer.recompute_cadence(&self.pace, self.target_fps());
        }
    }
    fn output_destroyed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        if let Some(idx) = self.outs.iter().position(|o| o.output == output) {
            self.outs[idx].gpu_surface = None;
            self.outs[idx].format = None;
            self.pace[idx].configured = false;
            self.pace[idx].frame_pending = false;
            self.pace[idx].stalled = false;
            self.pace[idx].last_vblank = None;
            let fps = self.target_fps();
            self.pacer.on_frame_barrier(&self.pace, fps, Instant::now());
        }
    }
}

impl LayerShellHandler for Saver {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        if let Some(idx) = self.outs.iter().position(|o| &o.layer == layer) {
            self.outs[idx].gpu_surface = None;
            self.outs[idx].format = None;
            self.pace[idx].configured = false;
            self.pace[idx].frame_pending = false;
            self.pace[idx].stalled = false;
            self.pace[idx].last_vblank = None;
            let fps = self.target_fps();
            self.pacer.on_frame_barrier(&self.pace, fps, Instant::now());
        }
        if self.outs.iter().all(|o| o.format.is_none()) {
            self.exit = Some("the compositor closed the surfaces");
        }
    }

    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        layer: &LayerSurface,
        configure: LayerSurfaceConfigure,
        _serial: u32,
    ) {
        let Some(idx) = self.outs.iter().position(|o| &o.layer == layer) else { return };
        let (w, h) = configure.new_size;
        let (w, h) = if w == 0 || h == 0 {
            (self.outs[idx].logical[2] as u32, self.outs[idx].logical[3] as u32)
        } else {
            (w, h)
        };
        if let Err(e) = self.configure_output(idx, w, h) {
            self.failed = Some(e);
        }
    }
}

impl SeatHandler for Saver {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seats
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(
        &mut self,
        _: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        cap: Capability,
    ) {
        if cap == Capability::Pointer && self.pointer.is_none() {
            self.pointer = self.seats.get_pointer(qh, &seat).ok();
        }
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = Some(seat.get_keyboard(qh, KeyWatch));
        }
    }
    fn remove_capability(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: wl_seat::WlSeat,
        cap: Capability,
    ) {
        if cap == Capability::Pointer
            && let Some(p) = self.pointer.take()
        {
            p.release();
        }
        if cap == Capability::Keyboard
            && let Some(k) = self.keyboard.take()
        {
            k.release();
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl PointerHandler for Saver {
    fn pointer_frame(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        pointer: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        for event in events {
            match event.kind {
                PointerEventKind::Enter { serial } => {
                    // Hide the cursor: it would sit still on the panel.
                    pointer.set_cursor(serial, None, 0, 0);
                    self.pointer_from = Some(event.position);
                }
                PointerEventKind::Motion { .. } => {
                    let from = *self.pointer_from.get_or_insert(event.position);
                    let (dx, dy) = (event.position.0 - from.0, event.position.1 - from.1);
                    if (dx * dx + dy * dy).sqrt() > NUDGE {
                        self.wake("the pointer moved");
                    }
                }
                PointerEventKind::Press { .. } | PointerEventKind::Axis { .. } => {
                    self.wake("a button or wheel")
                }
                _ => {}
            }
        }
    }
}

/// Any key press ends the saver; which key doesn't matter, so there is no
/// keymap to load.
struct KeyWatch;

impl Dispatch2<wl_keyboard::WlKeyboard, Saver> for KeyWatch {
    fn event(
        &self,
        state: &mut Saver,
        _: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &Connection,
        _: &QueueHandle<Saver>,
    ) {
        if let wl_keyboard::Event::Key {
            state: wayland_client::WEnum::Value(wl_keyboard::KeyState::Pressed),
            ..
        } = event
        {
            state.wake("a key");
        }
    }
}

delegate_registry!(Saver);

impl ProvidesRegistryState for Saver {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    registry_handlers![OutputState, SeatState];
}

smithay_client_toolkit::delegate_dispatch2!(Saver);

#[cfg(test)]
mod tests {
    use super::*;

    fn configured_slot(refresh_mhz: Option<u32>) -> OutputSlot {
        OutputSlot { configured: true, refresh_mhz, ..Default::default() }
    }

    #[test]
    fn vblank_stride_snaps_near_divisors_without_overshooting() {
        assert_eq!(vblank_stride(59.951, 30), 2);
        assert_eq!(vblank_stride(59.951, 15), 4);
        assert_eq!(vblank_stride(59.951, 60), 1);
        assert_eq!(vblank_stride(60.02, 30), 2);
        assert_eq!(vblank_stride(60.02, 60), 1);
        assert_eq!(vblank_stride(120.0, 30), 4);
        assert_eq!(vblank_stride(120.0, 60), 2);
        assert_eq!(vblank_stride(144.0, 30), 5);
        assert_eq!(vblank_stride(144.0, 60), 3);
        assert_eq!(vblank_stride(75.0, 30), 3);
    }

    #[test]
    fn ntsc_59_95_at_30fps_holds_exact_two_vblank_cadence() {
        let t0 = Instant::now();
        let vblank = Duration::from_secs_f64(1.0 / 59.951);
        let phase_offset = Duration::from_micros(400);
        let target_fps = 30;
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![configured_slot(Some(59_951)), configured_slot(Some(59_951))];

        assert!(pacer.should_draw(&mut slots, target_fps, t0));
        // Initial frame commits before the 2nd vblank (at k = 0 -> latches on k = 1).
        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, target_fps, t0 + Duration::from_millis(3));

        // Initial callbacks arrive on vblank index 1.
        let vb1_out0 = t0 + vblank;
        let vb1_out1 = vb1_out0 + phase_offset;
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb1_out0);
        pacer.on_frame_barrier(&slots, target_fps, vb1_out0);
        assert!(matches!(pacer.state, PacerState::WaitingVblank { .. }));

        slots[1].frame_pending = false;
        slots[1].last_vblank = Some(vb1_out1);
        pacer.on_frame_barrier(&slots, target_fps, vb1_out1);

        let mut base_k: u32 = 1;
        for frame_idx in 0..600u32 {
            let next_draw = match pacer.state {
                PacerState::WaitingCadence { next_draw, .. } => next_draw,
                ref other => panic!("frame {frame_idx}: expected WaitingCadence, got {other:?}"),
            };
            assert!(!pacer.should_draw(
                &mut slots,
                target_fps,
                next_draw - Duration::from_millis(1)
            ));
            assert!(pacer.should_draw(&mut slots, target_fps, next_draw));

            let render_latency = Duration::from_millis(2 + u64::from(frame_idx % 4));
            let commit_at = next_draw + render_latency;
            let prev_vblank_out1 = t0 + vblank * (base_k + 1) + phase_offset;
            let next_vblank_out0 = t0 + vblank * (base_k + 2);
            assert!(
                next_draw > prev_vblank_out1 + Duration::from_millis(2),
                "frame {frame_idx} started too close to previous vblank"
            );
            assert!(
                commit_at < next_vblank_out0 - Duration::from_millis(2),
                "frame {frame_idx} committed too close to target vblank"
            );

            for slot in &mut slots {
                slot.frame_pending = true;
            }
            pacer.on_presented(&slots, 2, target_fps, commit_at);

            base_k += 2;
            let cur_out0 = t0 + vblank * base_k;
            let cur_out1 = cur_out0 + phase_offset;
            slots[0].frame_pending = false;
            slots[0].last_vblank = Some(cur_out0);
            pacer.on_frame_barrier(&slots, target_fps, cur_out0);
            slots[1].frame_pending = false;
            slots[1].last_vblank = Some(cur_out1);
            pacer.on_frame_barrier(&slots, target_fps, cur_out1);
        }
    }

    #[test]
    fn dual_output_waits_for_both_frame_callbacks_and_handles_phase_offset() {
        let t0 = Instant::now();
        let vblank = Duration::from_secs_f64(1.0 / 59.951);
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![configured_slot(Some(59_951)), configured_slot(Some(59_951))];

        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, 30, t0);

        let vb0 = t0 + Duration::from_millis(16);
        let vb1 = vb0 + Duration::from_millis(6);

        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb0);
        pacer.on_frame_barrier(&slots, 30, vb0);
        assert!(matches!(pacer.state, PacerState::WaitingVblank { .. }));
        assert!(!pacer.should_draw(&mut slots, 30, vb0 + Duration::from_millis(2)));

        slots[1].frame_pending = false;
        slots[1].last_vblank = Some(vb1);
        pacer.on_frame_barrier(&slots, 30, vb1);

        match pacer.state {
            PacerState::WaitingCadence { next_draw, .. } => {
                assert!(next_draw > vb1 + vblank);
                assert!(next_draw < vb0 + vblank * 2);
            }
            ref other => panic!("expected WaitingCadence, got {other:?}"),
        }
    }

    #[test]
    fn dual_output_one_vblank_desync_self_heals() {
        let t0 = Instant::now();
        let vblank = Duration::from_secs_f64(1.0 / 59.951);
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![configured_slot(Some(59_951)), configured_slot(Some(59_951))];

        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, 30, t0);

        let vb0 = t0 + vblank;
        let vb1 = t0 + vblank * 2;
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb0);
        pacer.on_frame_barrier(&slots, 30, vb0);
        slots[1].frame_pending = false;
        slots[1].last_vblank = Some(vb1);
        pacer.on_frame_barrier(&slots, 30, vb1);

        match pacer.state {
            PacerState::WaitingCadence { next_draw, .. } => {
                assert!(next_draw > vb1 + vblank);
                assert!(next_draw < vb1 + vblank * 2);
            }
            ref other => panic!("expected WaitingCadence, got {other:?}"),
        }
    }

    #[test]
    fn stride_one_draws_immediately_after_all_vblanks() {
        let t0 = Instant::now();
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![configured_slot(Some(59_951)), configured_slot(Some(59_951))];

        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, 60, t0);

        let vb0 = t0 + Duration::from_millis(16);
        let vb1 = vb0 + Duration::from_micros(300);
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb0);
        pacer.on_frame_barrier(&slots, 60, vb0);
        slots[1].frame_pending = false;
        slots[1].last_vblank = Some(vb1);
        pacer.on_frame_barrier(&slots, 60, vb1);

        match pacer.state {
            PacerState::WaitingCadence { next_draw, .. } => assert_eq!(next_draw, vb1),
            ref other => panic!("expected WaitingCadence, got {other:?}"),
        }
        assert!(pacer.should_draw(&mut slots, 60, vb1));
    }

    #[test]
    fn watchdog_marks_stalled_output_and_rejoins_when_callback_returns() {
        let t0 = Instant::now();
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![configured_slot(Some(59_951)), configured_slot(Some(59_951))];

        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, 30, t0);

        let vb0 = t0 + Duration::from_millis(16);
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb0);
        pacer.on_frame_barrier(&slots, 30, vb0);
        assert!(!pacer.should_draw(&mut slots, 30, t0 + Duration::from_millis(100)));

        let watchdog_at = t0 + MIN_WATCHDOG;
        assert!(pacer.should_draw(&mut slots, 30, watchdog_at));
        assert!(!slots[0].stalled);
        assert!(slots[1].stalled);
        assert!(!slots[1].frame_pending);

        // Present again: stalled output 1 does not block output 0's vblank barrier.
        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, 30, watchdog_at);
        let vb0_next = watchdog_at + Duration::from_millis(17);
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb0_next);
        pacer.on_frame_barrier(&slots, 30, vb0_next);
        assert!(matches!(pacer.state, PacerState::WaitingCadence { .. }));

        // Output 1 wakes up and delivers a frame callback, then rejoins the barrier.
        let wake_at = watchdog_at + Duration::from_millis(35);
        slots[1].frame_pending = false;
        slots[1].stalled = false;
        slots[1].last_vblank = Some(wake_at);
        pacer.on_frame_barrier(&slots, 30, wake_at);

        for slot in &mut slots {
            slot.frame_pending = true;
        }
        pacer.on_presented(&slots, 2, 30, wake_at);
        let vb0_third = wake_at + Duration::from_millis(16);
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb0_third);
        pacer.on_frame_barrier(&slots, 30, vb0_third);
        assert!(matches!(pacer.state, PacerState::WaitingVblank { .. }));
    }

    #[test]
    fn fixed_fallback_does_not_drift_and_skips_overruns() {
        let t0 = Instant::now();
        let interval = Duration::from_nanos(33_333_333);
        assert_eq!(
            advance_fixed_deadline(t0, interval, t0 + Duration::from_millis(5)),
            t0 + interval
        );
        assert_eq!(
            advance_fixed_deadline(t0, interval, t0 + interval * 2 + Duration::from_millis(5)),
            t0 + interval * 3
        );
    }

    #[test]
    fn startup_barrier_waits_for_all_outputs_or_grace() {
        let t0 = Instant::now();
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![OutputSlot::default(), OutputSlot::default()];
        assert!(!pacer.should_draw(&mut slots, 30, t0 + STARTUP_GRACE));

        slots[0].configured = true;
        assert!(!pacer.should_draw(&mut slots, 30, t0 + Duration::from_millis(100)));
        assert!(pacer.should_draw(&mut slots, 30, t0 + STARTUP_GRACE));

        slots[1].configured = true;
        assert!(pacer.should_draw(&mut slots, 30, t0));
    }

    #[test]
    fn cheap_mode_recomputes_pending_cadence() {
        let t0 = Instant::now();
        let vblank = Duration::from_secs_f64(1.0 / 59.951);
        let mut pacer = Pacer::new(t0);
        let mut slots = vec![configured_slot(Some(59_951))];
        slots[0].frame_pending = true;
        pacer.on_presented(&slots, 1, 30, t0);
        let vb = t0 + vblank;
        slots[0].frame_pending = false;
        slots[0].last_vblank = Some(vb);
        pacer.on_frame_barrier(&slots, 30, vb);

        let normal_draw = match pacer.state {
            PacerState::WaitingCadence { next_draw, .. } => next_draw,
            ref other => panic!("expected WaitingCadence, got {other:?}"),
        };
        pacer.recompute_cadence(&slots, 15);
        match pacer.state {
            PacerState::WaitingCadence { next_draw, .. } => {
                assert!(next_draw > normal_draw + vblank);
                assert!(next_draw < vb + vblank * 4);
            }
            ref other => panic!("expected WaitingCadence, got {other:?}"),
        }
    }
}
