//! `layover doctor`'s checks that are plain data: what the compositor
//! offers against what the config asks of it, the waybar module, the lock
//! command and where a library is. The CLI gathers the facts (Wayland
//! globals, the GPU, pactl, the daemon) and prints the checks.
//!
//! Each check is one line: `ok`, `fail` (something Layover needs is missing
//! or broken) or `info` (optional, or only worth knowing).

use crate::config::{Config, LockAt};
use crate::span::Span;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Fail,
    Info,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Check {
    pub status: Status,
    pub what: String,
    pub detail: String,
}

impl Check {
    pub fn new(status: Status, what: &str, detail: impl Into<String>) -> Check {
        Check { status, what: what.into(), detail: detail.into() }
    }

    pub fn ok(what: &str, detail: impl Into<String>) -> Check {
        Check::new(Status::Ok, what, detail)
    }

    pub fn fail(what: &str, detail: impl Into<String>) -> Check {
        Check::new(Status::Fail, what, detail)
    }

    pub fn info(what: &str, detail: impl Into<String>) -> Check {
        Check::new(Status::Info, what, detail)
    }

    /// `ok   what: detail`, the way the sibling apps' doctors print.
    pub fn line(&self) -> String {
        let tag = match self.status {
            Status::Ok => "ok  ",
            Status::Fail => "fail",
            Status::Info => "info",
        };
        if self.detail.is_empty() {
            format!("{tag} {}", self.what)
        } else {
            format!("{tag} {}: {}", self.what, self.detail)
        }
    }
}

/// Any check failed: `layover doctor` exits 1.
pub fn failed(checks: &[Check]) -> bool {
    checks.iter().any(|c| c.status == Status::Fail)
}

pub const IDLE: &str = "ext_idle_notifier_v1";
pub const LAYER_SHELL: &str = "zwlr_layer_shell_v1";
pub const OUTPUT_POWER: &str = "zwlr_output_power_manager_v1";

/// What the compositor's globals (`(interface, version)`) mean for this
/// config: idle notifications for the line, layer-shell for the saver and
/// output power for the dark.
pub fn compositor(globals: &[(String, u32)], cfg: &Config) -> Vec<Check> {
    let version = |name: &str| globals.iter().filter(|(i, _)| i == name).map(|(_, v)| *v).max();
    let mut out = vec![];
    out.push(match version(IDLE) {
        Some(v) if v >= 2 => Check::ok(
            "ext-idle-notify-v1",
            format!("version {v}: idle counts input; inhibitors are read from Hyprland"),
        ),
        Some(v) => Check::ok(
            "ext-idle-notify-v1",
            format!(
                "version {v} only: every idle inhibitor holds the line, holds.ignore can't apply"
            ),
        ),
        None => Check::fail("ext-idle-notify-v1", "missing: Layover can't tell when you're idle"),
    });
    out.push(match version(LAYER_SHELL) {
        Some(v) => {
            Check::ok("wlr-layer-shell", format!("version {v}: the saver covers each screen"))
        }
        None => Check::fail("wlr-layer-shell", "missing: the saver can't cover the screens"),
    });
    let dark = !matches!(cfg.line.dark, Span::Off) || !matches!(cfg.line.locked_dark, Span::Off);
    out.push(match (version(OUTPUT_POWER), cfg.line.dark_command.is_empty()) {
        (Some(v), _) => Check::ok(
            "wlr-output-power-management",
            format!("version {v}: the dark turns the screens off"),
        ),
        (None, false) => Check::info(
            "wlr-output-power-management",
            "missing: the dark runs line.dark_command and line.wake_command",
        ),
        (None, true) if dark => Check::fail(
            "wlr-output-power-management",
            "missing and line.dark_command is empty: Layover can't turn the screens off",
        ),
        (None, true) => Check::info("wlr-output-power-management", "missing; the dark is off"),
    });
    out
}

/// Whether a waybar config runs `layover bar`.
pub fn module_in(text: &str) -> bool {
    text.contains("layover bar")
}

/// The lock command, given where its program was found (`None`: nowhere).
pub fn lock(cfg: &Config, found: Option<PathBuf>) -> Check {
    let prog = cfg.line.lock_command.first().map(String::as_str).unwrap_or("");
    match (cfg.line.lock, found) {
        (LockAt::Off, _) => Check::info("lock", "line.lock is off; Layover never locks"),
        (_, Some(p)) => Check::ok("lock", format!("{prog} ({})", p.display())),
        (_, None) => {
            Check::fail("lock", format!("`{prog}` is not installed; the session can't lock"))
        }
    }
}

/// Directories the dynamic linker looks in for a library.
fn lib_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("LD_LIBRARY_PATH")
        .map(|v| std::env::split_paths(&v).collect())
        .unwrap_or_default();
    for d in [
        "/usr/lib",
        "/usr/lib64",
        "/lib",
        "/lib64",
        "/usr/local/lib",
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
    ] {
        dirs.push(PathBuf::from(d));
    }
    dirs
}

/// The first `<stem>.so*` in the linker's directories.
pub fn find_lib(stem: &str) -> Option<PathBuf> {
    let prefix = format!("{stem}.so");
    lib_dirs().into_iter().find_map(|d| {
        std::fs::read_dir(&d)
            .into_iter()
            .flatten()
            .flatten()
            .find(|e| e.file_name().to_str().is_some_and(|n| n.starts_with(&prefix)))
            .map(|e| e.path())
    })
}

/// The drawer's libraries: GTK 4 and gtk4-layer-shell.
pub fn libraries() -> Vec<Check> {
    [("GTK 4", "libgtk-4"), ("gtk4-layer-shell", "libgtk4-layer-shell")]
        .into_iter()
        .map(|(what, stem)| match find_lib(stem) {
            Some(p) => Check::ok(what, format!("{} (the drawer)", p.display())),
            None => Check::fail(what, format!("{stem}.so not found; the drawer needs it")),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn globals(list: &[(&str, u32)]) -> Vec<(String, u32)> {
        list.iter().map(|(i, v)| (i.to_string(), *v)).collect()
    }

    fn status(checks: &[Check], what: &str) -> Status {
        checks.iter().find(|c| c.what == what).expect(what).status
    }

    #[test]
    fn lines_match_the_siblings() {
        assert_eq!(Check::ok("config", "~/x").line(), "ok   config: ~/x");
        assert_eq!(Check::fail("daemon", "").line(), "fail daemon");
        assert_eq!(Check::info("feeds", "none").line(), "info feeds: none");
        assert!(!failed(&[Check::ok("a", ""), Check::info("b", "")]));
        assert!(failed(&[Check::ok("a", ""), Check::fail("b", "")]));
    }

    #[test]
    fn a_full_compositor_passes() {
        let g = globals(&[("wl_compositor", 6), (IDLE, 2), (LAYER_SHELL, 5), (OUTPUT_POWER, 1)]);
        let checks = compositor(&g, &Config::default());
        assert!(!failed(&checks), "{checks:?}");
        assert!(checks[0].detail.starts_with("version 2"));
    }

    #[test]
    fn what_a_missing_protocol_costs() {
        let cfg = Config::default();
        let checks = compositor(&globals(&[(LAYER_SHELL, 4), (OUTPUT_POWER, 1)]), &cfg);
        assert_eq!(status(&checks, "ext-idle-notify-v1"), Status::Fail);

        let checks = compositor(&globals(&[(IDLE, 1), (OUTPUT_POWER, 1)]), &cfg);
        assert_eq!(status(&checks, "ext-idle-notify-v1"), Status::Ok);
        assert!(checks[0].detail.contains("version 1 only"));
        assert_eq!(status(&checks, "wlr-layer-shell"), Status::Fail);

        // No output power: a dark command stands in, else the dark can't work.
        let g = globals(&[(IDLE, 2), (LAYER_SHELL, 4)]);
        assert_eq!(status(&compositor(&g, &cfg), "wlr-output-power-management"), Status::Fail);
        let with_command =
            Config::parse("[line]\ndark_command = [\"true\"]\nwake_command = [\"true\"]").unwrap();
        assert_eq!(
            status(&compositor(&g, &with_command), "wlr-output-power-management"),
            Status::Info
        );
    }

    #[test]
    fn the_waybar_module() {
        assert!(module_in(r#""custom/layover": { "exec": "~/.local/bin/layover bar" }"#));
        assert!(!module_in(r#""custom/layover": { "exec": "layover status" }"#));
    }

    #[test]
    fn the_lock_command() {
        let cfg = Config::default();
        assert_eq!(lock(&cfg, Some("/usr/bin/hyprlock".into())).status, Status::Ok);
        let missing = lock(&cfg, None);
        assert_eq!(missing.status, Status::Fail);
        assert!(missing.detail.contains("hyprlock"));
        let off = Config::parse("[line]\nlock = \"off\"").unwrap();
        assert_eq!(lock(&off, None).status, Status::Info);
    }
}
