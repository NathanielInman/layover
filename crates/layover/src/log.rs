//! The daemon log: `$LAYOVER_STATE_DIR/daemon.log`, rolled over at 1 MB.

use layover_core::paths;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::process::Stdio;

const ROLL_AT: u64 = 1 << 20;

fn open() -> Option<File> {
    let path = paths::log_file();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > ROLL_AT) {
        let _ = std::fs::rename(&path, path.with_extension("log.old"));
    }
    OpenOptions::new().create(true).append(true).open(path).ok()
}

/// Local time of a Unix second as `14:02:11`.
pub fn clock_at(unix: u64) -> String {
    // SAFETY: localtime_r writes only into our own struct.
    unsafe {
        let t = unix as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
    }
}

/// Local time as `2026-11-20 14:02:11`.
pub fn stamp() -> String {
    // SAFETY: time and localtime_r write only into our own struct.
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec
        )
    }
}

pub fn log(msg: &str) {
    let line = format!("{} {msg}", stamp());
    eprintln!("{line}");
    if let Some(mut f) = open() {
        let _ = writeln!(f, "{line}");
    }
}

/// Where a child's stdout and stderr go: the log, else nowhere.
pub fn child_output() -> (Stdio, Stdio) {
    match (open(), open()) {
        (Some(a), Some(b)) => (Stdio::from(a), Stdio::from(b)),
        _ => (Stdio::null(), Stdio::null()),
    }
}
