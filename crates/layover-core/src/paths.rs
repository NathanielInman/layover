//! Where Layover keeps its socket, logs and config. Each has a `LAYOVER_*`
//! override so a dev build never touches an installed one.

use std::path::PathBuf;

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn home() -> PathBuf {
    env_dir("HOME").unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// `$LAYOVER_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/layover`.
pub fn runtime_dir() -> PathBuf {
    env_dir("LAYOVER_RUNTIME_DIR")
        .or_else(|| env_dir("XDG_RUNTIME_DIR").map(|d| d.join("layover")))
        .unwrap_or_else(|| std::env::temp_dir().join(format!("layover-{}", uid())))
}

/// `$LAYOVER_STATE_DIR`, else `$XDG_STATE_HOME/layover`, else
/// `~/.local/state/layover`.
pub fn state_dir() -> PathBuf {
    env_dir("LAYOVER_STATE_DIR")
        .or_else(|| env_dir("XDG_STATE_HOME").map(|d| d.join("layover")))
        .unwrap_or_else(|| home().join(".local/state/layover"))
}

/// `$LAYOVER_CONFIG_DIR`, else `$XDG_CONFIG_HOME/layover`, else
/// `~/.config/layover`.
pub fn config_dir() -> PathBuf {
    env_dir("LAYOVER_CONFIG_DIR")
        .or_else(|| env_dir("XDG_CONFIG_HOME").map(|d| d.join("layover")))
        .unwrap_or_else(|| home().join(".config/layover"))
}

/// `$LAYOVER_CACHE_DIR`, else `$XDG_CACHE_HOME/layover`, else
/// `~/.cache/layover`.
pub fn cache_dir() -> PathBuf {
    env_dir("LAYOVER_CACHE_DIR")
        .or_else(|| env_dir("XDG_CACHE_HOME").map(|d| d.join("layover")))
        .unwrap_or_else(|| home().join(".cache/layover"))
}

/// The drawer's thumbnails, written by `layover thumbs`.
pub fn thumbs_dir() -> PathBuf {
    cache_dir().join("thumbs")
}

/// A wear heat map, written by `layover wear`.
pub fn heat_map(id: &str) -> PathBuf {
    state_dir().join("wear").join(format!("{id}.png"))
}

pub fn config_file() -> PathBuf {
    config_dir().join("layover.toml")
}

pub fn socket() -> PathBuf {
    runtime_dir().join("daemon.sock")
}

pub fn log_file() -> PathBuf {
    state_dir().join("daemon.log")
}

pub fn board_log() -> PathBuf {
    state_dir().join("board.log")
}

/// The wear test's last results, written by `layover wear`.
pub fn wear_cache() -> PathBuf {
    state_dir().join("wear.json")
}

/// The drawer's own stylesheet, layered over the bar's look.
pub fn style_file() -> PathBuf {
    config_dir().join("style.css")
}

/// `$XDG_CONFIG_HOME/waybar`, else `~/.config/waybar`.
pub fn waybar_dir() -> PathBuf {
    env_dir("XDG_CONFIG_HOME").unwrap_or_else(|| home().join(".config")).join("waybar")
}

fn uid() -> String {
    std::env::var("UID").unwrap_or_else(|_| "user".into())
}
