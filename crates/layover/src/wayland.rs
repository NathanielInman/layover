//! The daemon's Wayland connection: idle notifications for each station and
//! output power for the dark. It runs on its own thread and reports to the
//! daemon's channel; output power is switched from the daemon's thread.

use crate::daemon::Msg;
use anyhow::{Context, Result, anyhow};
use layover_core::config::{Config, LockAt};
use layover_core::span::Span;
use layover_core::state::Station;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use wayland_client::{
    Connection, Dispatch, Proxy, QueueHandle,
    globals::{GlobalListContents, registry_queue_init},
    protocol::{wl_output, wl_registry, wl_seat},
};
use wayland_protocols::ext::idle_notify::v1::client::{
    ext_idle_notification_v1, ext_idle_notifier_v1,
};
use wayland_protocols_wlr::output_power_management::v1::client::{
    zwlr_output_power_manager_v1, zwlr_output_power_v1,
};

/// The idle probe's timeout: the desk has been idle this long when it fires.
pub const PROBE_SECS: u64 = 10;

/// The idle probe's notification.
pub struct Probe;

pub struct WlState {
    tx: Sender<Msg>,
    outputs: Arc<Mutex<Vec<wl_output::WlOutput>>>,
}

/// What the compositor offers, for the log.
pub struct Offer {
    /// `get_input_idle_notification`: idle that ignores inhibitors.
    pub input_idle: bool,
    pub output_power: bool,
}

/// Switches every output's power.
pub struct Screens {
    conn: Connection,
    qh: QueueHandle<WlState>,
    manager: Option<zwlr_output_power_manager_v1::ZwlrOutputPowerManagerV1>,
    outputs: Arc<Mutex<Vec<wl_output::WlOutput>>>,
    controls: Vec<zwlr_output_power_v1::ZwlrOutputPowerV1>,
}

impl Screens {
    /// Turn every output off or on. False when the compositor has no output
    /// power management.
    pub fn set(&mut self, on: bool) -> bool {
        let Some(manager) = &self.manager else { return false };
        let mode =
            if on { zwlr_output_power_v1::Mode::On } else { zwlr_output_power_v1::Mode::Off };
        // Old controls first: one control per output at a time.
        for c in self.controls.drain(..) {
            c.destroy();
        }
        for output in self.outputs.lock().expect("outputs lock").iter() {
            if !output.is_alive() {
                continue;
            }
            let control = manager.get_output_power(output, &self.qh, ());
            control.set_mode(mode);
            self.controls.push(control);
        }
        let _ = self.conn.flush();
        true
    }
}

pub fn start(cfg: &Config, tx: Sender<Msg>) -> Result<(Screens, Offer)> {
    let conn =
        Connection::connect_to_env().context("no Wayland display (is WAYLAND_DISPLAY set?)")?;
    let (globals, mut queue) =
        registry_queue_init::<WlState>(&conn).context("reading Wayland globals")?;
    let qh = queue.handle();
    let outputs = Arc::new(Mutex::new(Vec::new()));
    let mut state = WlState { tx: tx.clone(), outputs: outputs.clone() };

    let seat: wl_seat::WlSeat =
        globals.bind(&qh, 1..=9, ()).context("the compositor has no seat")?;
    let notifier: ext_idle_notifier_v1::ExtIdleNotifierV1 =
        globals.bind(&qh, 1..=2, ()).map_err(|_| {
            anyhow!(
                "the compositor has no ext-idle-notify-v1, so Layover can't tell when you're idle"
            )
        })?;
    let manager: Option<zwlr_output_power_manager_v1::ZwlrOutputPowerManagerV1> =
        globals.bind(&qh, 1..=1, ()).ok();
    for g in globals.contents().clone_list() {
        if g.interface == wl_output::WlOutput::interface().name {
            let o: wl_output::WlOutput = globals.registry().bind(g.name, g.version.min(4), &qh, ());
            outputs.lock().expect("outputs lock").push(o);
        }
    }

    let input_idle = notifier.version() >= 2;
    let ms = |d: std::time::Duration| d.as_millis().min(u32::MAX as u128) as u32;
    let mut stations = Vec::new();
    if let Span::After(d) = cfg.line.saver {
        stations.push((Station::Saver, ms(d)));
    }
    if let LockAt::After(d) = cfg.line.lock {
        stations.push((Station::Lock, ms(d)));
    }
    if let Span::After(d) = cfg.line.dark {
        stations.push((Station::Dark, ms(d)));
    }
    if let Span::After(d) = cfg.line.locked_dark {
        stations.push((Station::LockedDark, ms(d)));
    }
    for (station, timeout) in stations {
        if input_idle {
            notifier.get_input_idle_notification(timeout, &seat, &qh, station);
        } else {
            notifier.get_idle_notification(timeout, &seat, &qh, station);
        }
    }
    // A short probe tells when the last input was, for the countdowns.
    let probe = ms(std::time::Duration::from_secs(PROBE_SECS));
    if input_idle {
        notifier.get_input_idle_notification(probe, &seat, &qh, Probe);
    } else {
        notifier.get_idle_notification(probe, &seat, &qh, Probe);
    }
    conn.flush().context("talking to the compositor")?;

    std::thread::Builder::new()
        .name("wayland".into())
        .spawn(move || {
            loop {
                if let Err(e) = queue.blocking_dispatch(&mut state) {
                    let _ = state.tx.send(Msg::WaylandGone(e.to_string()));
                    break;
                }
            }
        })
        .context("starting the Wayland thread")?;

    let offer = Offer { input_idle, output_power: manager.is_some() };
    Ok((Screens { conn, qh, manager, outputs, controls: Vec::new() }, offer))
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for WlState {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global { name, interface, version } = event
            && interface == wl_output::WlOutput::interface().name
        {
            let o: wl_output::WlOutput = registry.bind(name, version.min(4), qh, ());
            state.outputs.lock().expect("outputs lock").push(o);
        }
    }
}

impl Dispatch<ext_idle_notification_v1::ExtIdleNotificationV1, Station> for WlState {
    fn event(
        state: &mut Self,
        _: &ext_idle_notification_v1::ExtIdleNotificationV1,
        event: ext_idle_notification_v1::Event,
        station: &Station,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let msg = match event {
            ext_idle_notification_v1::Event::Idled => Msg::Idled(*station),
            ext_idle_notification_v1::Event::Resumed => Msg::Resumed,
            _ => return,
        };
        let _ = state.tx.send(msg);
    }
}

impl Dispatch<ext_idle_notification_v1::ExtIdleNotificationV1, Probe> for WlState {
    fn event(
        state: &mut Self,
        _: &ext_idle_notification_v1::ExtIdleNotificationV1,
        event: ext_idle_notification_v1::Event,
        _: &Probe,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let ext_idle_notification_v1::Event::Idled = event {
            let _ = state.tx.send(Msg::IdleProbe);
        }
    }
}

impl Dispatch<zwlr_output_power_v1::ZwlrOutputPowerV1, ()> for WlState {
    fn event(
        state: &mut Self,
        _: &zwlr_output_power_v1::ZwlrOutputPowerV1,
        event: zwlr_output_power_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zwlr_output_power_v1::Event::Failed = event {
            let _ = state
                .tx
                .send(Msg::Note("the compositor refused to change an output's power".into()));
        }
    }
}

macro_rules! ignore_events {
    ($($t:ty),*) => {$(
        impl Dispatch<$t, ()> for WlState {
            fn event(_: &mut Self, _: &$t, _: <$t as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
    )*};
}

ignore_events!(
    wl_seat::WlSeat,
    wl_output::WlOutput,
    ext_idle_notifier_v1::ExtIdleNotifierV1,
    zwlr_output_power_manager_v1::ZwlrOutputPowerManagerV1
);
