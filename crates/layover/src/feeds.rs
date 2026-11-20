//! Runs each tool's `bar` command (the lamp it prints for waybar) and hands
//! the lines to the daemon. Every feed has its own thread and child, which
//! dies with the daemon; a feed that ends is started again with backoff.
//! Nothing here blocks the daemon's loop.

use crate::daemon::Msg;
use crate::log::log;
use layover_core::config::Feeds;
use layover_core::feeds::{Feed, parse_lamp};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

/// Start every configured feed whose command is installed.
pub fn start(cfg: &Feeds, tx: &Sender<Msg>) {
    let mut reading = Vec::new();
    let mut missing = Vec::new();
    for feed in Feed::ALL {
        let Some((prog, args)) = cfg.command(feed).split_first() else { continue };
        match resolve(prog) {
            Some(path) => {
                reading.push(feed.key());
                spawn(feed, path, args.to_vec(), tx.clone());
            }
            None => missing.push(feed.key()),
        }
    }
    let mut line = format!(
        "feeds: reading {}",
        if reading.is_empty() { "none".into() } else { reading.join(", ") }
    );
    if !missing.is_empty() {
        line.push_str(&format!(" (not installed: {})", missing.join(", ")));
    }
    log(&line);
}

fn executable(p: &Path) -> bool {
    p.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// A program by path (`~/` allowed) or by name on `PATH`, then the places a
/// user service's `PATH` often lacks.
fn resolve(prog: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    if let Some(rest) = prog.strip_prefix("~/") {
        let p = home.join(rest);
        return executable(&p).then_some(p);
    }
    if prog.contains('/') {
        let p = PathBuf::from(prog);
        return executable(&p).then_some(p);
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain([home.join(".local/bin"), "/usr/local/bin".into(), "/usr/bin".into()])
        .map(|d| d.join(prog))
        .find(|p| executable(p))
}

fn spawn(feed: Feed, path: PathBuf, args: Vec<String>, tx: Sender<Msg>) {
    let name = format!("feed-{}", feed.key());
    let _ = std::thread::Builder::new().name(name).spawn(move || {
        let mut backoff = 2u64;
        loop {
            let started = Instant::now();
            let mut cmd = Command::new(&path);
            cmd.args(&args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
            // SAFETY: prctl only; the feed dies with the daemon.
            unsafe {
                cmd.pre_exec(|| {
                    libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                    Ok(())
                });
            }
            match cmd.spawn() {
                Ok(mut child) => {
                    if let Some(out) = child.stdout.take() {
                        for line in BufReader::new(out).lines() {
                            let Ok(line) = line else { break };
                            let Some(lamp) = parse_lamp(&line) else { continue };
                            if tx.send(Msg::Feed(feed, Some(lamp))).is_err() {
                                let _ = child.kill();
                                let _ = child.wait();
                                return;
                            }
                        }
                    }
                    let _ = child.kill();
                    let _ = child.wait();
                }
                Err(e) => log(&format!("feed {}: can't run {}: {e}", feed.key(), path.display())),
            }
            if tx.send(Msg::Feed(feed, None)).is_err() {
                return;
            }
            if started.elapsed() > Duration::from_secs(60) {
                backoff = 2;
            }
            log(&format!("feed {} ended; starting it again in {backoff}s", feed.key()));
            std::thread::sleep(Duration::from_secs(backoff));
            backoff = (backoff * 2).min(60);
        }
    });
}
