//! `layover saver`: one overlay layer surface per output, drawn by the
//! renderer, until any input or SIGTERM. The daemon starts it; `layover
//! saver --hack <id> --for 20s` previews one hack by hand.

use anyhow::{Context, Result, anyhow, bail};
use layover_core::config::Config;
use layover_hacks::Hack;
use layover_hacks::gpu::{self, Gpu};
use layover_hacks::renderer::{CareSettings, Frame, Placement, Renderer};
use raw_window_handle::{
    RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle,
};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_registry,
    dispatch2::Dispatch2,
    output::{OutputHandler, OutputState},
    reexports::{
        calloop::{
            EventLoop,
            timer::{TimeoutAction, Timer},
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

struct Saver {
    registry: RegistryState,
    seats: SeatState,
    outputs_state: OutputState,
    conn: Connection,
    instance: wgpu::Instance,
    gpu: Option<Gpu>,
    renderer: Option<Renderer>,
    outs: Vec<Out>,
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
    let mut state = Saver {
        registry: RegistryState::new(&globals),
        seats: SeatState::new(&globals, &qh),
        outputs_state: OutputState::new(&globals, &qh),
        conn: conn.clone(),
        instance: gpu::instance(),
        gpu: None,
        renderer: None,
        outs: Vec::new(),
        canvas: [1.0, 1.0],
        origin: [0, 0],
        care: CareSettings::from_config(&cfg.care),
        cfg: cfg.clone(),
        hacks: opts.hacks,
        started: Instant::now(),
        last_frame: Instant::now(),
        t_offset: (seed % 100_000) as f32 / 100.0,
        seed: ((seed >> 20) % 1000) as f32 / 1000.0,
        pointer: None,
        keyboard: None,
        pointer_from: None,
        exit: None,
        failed: None,
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
    }
    state.layout_canvas();

    let mut event_loop: EventLoop<Saver> =
        EventLoop::try_new().context("creating the event loop")?;
    WaylandSource::new(conn, queue)
        .insert(event_loop.handle())
        .map_err(|e| anyhow!("watching the Wayland socket: {e}"))?;
    let interval = Duration::from_secs_f64(1.0 / cfg.power.effective_fps().max(1) as f64);
    event_loop
        .handle()
        .insert_source(Timer::from_duration(interval), move |_, _, s: &mut Saver| {
            s.draw();
            TimeoutAction::ToDuration(interval)
        })
        .map_err(|e| anyhow!("starting the frame timer: {e}"))?;

    while state.exit.is_none() && state.failed.is_none() {
        if let Some(limit) = opts.run_for
            && state.started.elapsed() >= limit
        {
            state.exit = Some("time is up");
            break;
        }
        event_loop
            .dispatch(Some(Duration::from_millis(100)), &mut state)
            .context("dispatching Wayland events")?;
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

impl Saver {
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
            let scale = self.outs.iter().map(|o| o.scale).max().unwrap_or(1) as f32
                * self.cfg.power.effective_scale();
            renderer.resize(
                self.canvas,
                [(self.canvas[0] * scale).round() as u32, (self.canvas[1] * scale).round() as u32],
            );
            renderer.reset_limiter();
            for hack in &self.hacks {
                renderer.prepare(hack)?;
            }
            self.renderer = Some(renderer);
            self.gpu = Some(gpu);
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
                present_mode: wgpu::PresentMode::Fifo,
                color_space: wgpu::SurfaceColorSpace::Auto,
            },
        );
        out.format = Some(format);
        out.px = px;
        Ok(())
    }

    fn draw(&mut self) {
        if self.exit.is_some() || self.failed.is_some() || self.renderer.is_none() {
            return;
        }
        let now = Instant::now();
        let dt = now.duration_since(self.last_frame).as_secs_f32().min(1.0);
        self.last_frame = now;
        let elapsed = now.duration_since(self.started).as_secs_f32();
        let (hack, fade) = layover_hacks::showing(&self.hacks, &self.cfg.care, elapsed);
        let phase = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64()
            % 86_400.0;
        let frame = Frame { hack, t: self.t_offset + elapsed, phase, dt, seed: self.seed };
        if let Err(e) = self.draw_frame(&frame, fade) {
            self.failed = Some(e);
        }
    }

    fn draw_frame(&mut self, frame: &Frame, fade: f32) -> Result<()> {
        let gpu = self.gpu.as_ref().expect("gpu is ready");
        let renderer = self.renderer.as_mut().expect("renderer is ready");
        let mut enc = gpu.device.create_command_encoder(&Default::default());
        renderer.draw_canvas(&mut enc, frame)?;
        let mut frames = Vec::new();
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
            frames.push(texture);
        }
        gpu.queue.submit(Some(enc.finish()));
        for f in frames {
            gpu.queue.present(f);
        }
        Ok(())
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
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {}
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
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        if let Some(o) = self.outs.iter_mut().find(|o| o.output == output) {
            o.gpu_surface = None;
            o.format = None;
        }
    }
}

impl LayerShellHandler for Saver {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        if let Some(o) = self.outs.iter_mut().find(|o| &o.layer == layer) {
            o.gpu_surface = None;
            o.format = None;
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
