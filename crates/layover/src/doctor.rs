//! `layover doctor`: gathers what the compositor, the GPU, pactl, Hyprland,
//! the daemon and waybar say, and prints one line per check. Everything here
//! reads; the only programs it runs are `pactl` and `systemctl --user
//! is-active`. The plain-data checks are in `layover_core::doctor`.

use anyhow::{Context, Result};
use layover_core::config::Config;
use layover_core::doctor::{self, Check};
use layover_core::feeds::Feed;
use layover_core::paths;
use std::path::Path;
use wayland_client::{
    Connection, Dispatch, QueueHandle,
    globals::{GlobalListContents, registry_queue_init},
    protocol::wl_registry,
};

/// The path with the home folder written as `~`.
fn tilde(p: &Path) -> String {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    match p.strip_prefix(&home) {
        Ok(rest) if !home.as_os_str().is_empty() => format!("~/{}", rest.display()),
        _ => p.display().to_string(),
    }
}

struct Registry;

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for Registry {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

/// Every global the compositor offers, as `(interface, version)`.
fn globals() -> Result<Vec<(String, u32)>> {
    let conn =
        Connection::connect_to_env().context("no Wayland display (is WAYLAND_DISPLAY set?)")?;
    let (globals, _queue) =
        registry_queue_init::<Registry>(&conn).context("reading Wayland globals")?;
    Ok(globals.contents().clone_list().into_iter().map(|g| (g.interface, g.version)).collect())
}

fn config(checks: &mut Vec<Check>) -> Config {
    let path = paths::config_file();
    let cfg = match Config::load(&path) {
        Ok(c) => c,
        Err(e) => {
            checks.push(Check::fail("config", format!("{}: {e:#}", tilde(&path))));
            return Config::default();
        }
    };
    checks.push(if path.exists() {
        Check::ok("config", tilde(&path))
    } else {
        Check::info("config", "no config file, using the shipped defaults")
    });
    if let Err(e) = layover_hacks::rotation(&cfg.saver.hacks) {
        checks.push(Check::fail("hacks", format!("[saver] hacks: {e}")));
    }
    match cfg.loosened().len() {
        0 => {}
        n => checks.push(Check::info(
            "limits",
            format!(
                "{n} value{} looser than shipped (`layover check` lists them)",
                if n == 1 { " is" } else { "s are" }
            ),
        )),
    }
    cfg
}

fn daemon() -> Vec<Check> {
    let mut out = vec![];
    let alive = crate::ask(&layover_core::protocol::Request::Status);
    out.push(match &alive {
        Ok(lamp) => Check::ok(
            "daemon",
            format!("running: {}", lamp.tooltip.lines().next().unwrap_or_default()),
        ),
        Err(_) => Check::fail(
            "daemon",
            "not running (`systemctl --user start layover.service`, or `layover daemon`)",
        ),
    });
    let state = std::process::Command::new("systemctl")
        .args(["--user", "is-active", "layover.service"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    match state.as_deref() {
        Ok("active") => out.push(Check::ok("layover.service", "active")),
        Ok("failed") => out.push(Check::fail(
            "layover.service",
            format!("failed (see {})", tilde(&paths::log_file())),
        )),
        Ok(s) if alive.is_ok() => out.push(Check::info(
            "layover.service",
            format!("{s}; the daemon was started some other way"),
        )),
        Ok(s) => out.push(Check::info("layover.service", s.to_string())),
        Err(_) => {}
    }
    out
}

fn pactl() -> Check {
    match crate::daemon::command_output("pactl", &["-f", "json", "list", "sink-inputs"]) {
        Some(json) => match layover_core::holds::audio_playing(&json) {
            Ok(playing) => Check::ok(
                "pactl",
                format!(
                    "the audio and microphone holds read it (audio {})",
                    if playing { "playing" } else { "quiet" }
                ),
            ),
            Err(e) => Check::fail("pactl", format!("{e:#}")),
        },
        None if crate::feeds::resolve("pactl").is_some() => {
            Check::fail("pactl", "did not answer; the audio and microphone holds are off")
        }
        None => Check::fail("pactl", "not installed; the audio and microphone holds are off"),
    }
}

fn feeds(cfg: &Config) -> Check {
    let (mut reading, mut missing) = (vec![], vec![]);
    for feed in Feed::ALL {
        let Some(prog) = cfg.feeds.command(feed).first() else { continue };
        if crate::feeds::resolve(prog).is_some() {
            reading.push(feed.key());
        } else {
            missing.push(feed.key());
        }
    }
    let mut detail = if reading.is_empty() {
        "reading none".to_string()
    } else {
        format!("reading {}", reading.join(", "))
    };
    if !missing.is_empty() {
        detail.push_str(&format!(" (not installed: {})", missing.join(", ")));
    }
    Check::info("feeds", detail)
}

/// Everything `layover doctor` checks, in the order it prints them.
pub fn checks() -> Vec<Check> {
    let mut out = vec![];
    let cfg = config(&mut out);
    out.extend(daemon());
    match globals() {
        Ok(g) => out.extend(doctor::compositor(&g, &cfg)),
        Err(e) => out.push(Check::fail("Wayland", format!("{e:#}"))),
    }
    out.push(match layover_hacks::gpu::Gpu::headless() {
        Ok(gpu) => Check::ok("Vulkan", gpu.describe()),
        Err(e) => Check::fail("Vulkan", format!("{e:#}")),
    });
    out.push(pactl());
    if cfg.holds.inhibitors {
        out.push(match crate::daemon::hyprland_request("j/clients") {
            Some(_) => Check::ok("Hyprland IPC", "idle inhibitors are read from its clients"),
            None => Check::info("Hyprland IPC", "not found; apps' idle inhibitors are not seen"),
        });
    }
    let prog = cfg.line.lock_command.first().map(String::as_str).unwrap_or("");
    out.push(doctor::lock(&cfg, crate::feeds::resolve(prog)));
    for (key, cmd) in
        [("dark_command", &cfg.line.dark_command), ("wake_command", &cfg.line.wake_command)]
    {
        if let Some(prog) = cmd.first()
            && crate::feeds::resolve(prog).is_none()
        {
            out.push(Check::fail(key, format!("line.{key} runs `{prog}`, which is not installed")));
        }
    }
    out.push(feeds(&cfg));
    match layover_core::waybar::config_path() {
        Some(p) => {
            let text = std::fs::read_to_string(&p).unwrap_or_default();
            let has = doctor::module_in(&text);
            out.push(Check::new(
                if has { doctor::Status::Ok } else { doctor::Status::Fail },
                "waybar config",
                format!(
                    "{}: {}",
                    tilde(&p),
                    if has { "has `layover bar`" } else { "no module runs `layover bar`" }
                ),
            ));
        }
        None => out.push(Check::info("waybar config", "not found")),
    }
    out.push(match bar_anchor::compositor() {
        Some(wm) => {
            Check::ok("compositor", format!("{wm}: the drawer opens from the clicked moon"))
        }
        None => Check::info("compositor", "not Hyprland, sway or niri; the drawer opens centered"),
    });
    let board = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("layover-board")))
        .filter(|p| p.exists());
    out.push(match board {
        Some(p) => Check::ok("drawer", tilde(&p)),
        None => Check::info("drawer", "layover-board is not next to layover; it must be on PATH"),
    });
    out.extend(doctor::libraries());
    out
}
