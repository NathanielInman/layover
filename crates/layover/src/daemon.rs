//! `layover daemon`: the I/O around `layover_core::state::Model`. It turns
//! idle notifications, socket requests and child exits into events, gathers
//! holds when a station is reached, and carries out the effects. Rules about
//! what happens when belong in the model, with a test.

use crate::log::log;
use crate::wayland::{self, Screens};
use anyhow::{Context, Result, bail};
use layover_core::board::{BoardEvent, HackView};
use layover_core::config::Config;
use layover_core::feeds::{self, Desk, Feed, LampLine, LineUpdate, Reading};
use layover_core::holds::{self, HoldSnapshot};
use layover_core::lamp::Lamp;
use layover_core::paths;
use layover_core::protocol::{Reply, Request};
use layover_core::state::{Effect, Event, Model, Station};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

pub enum Msg {
    Idled(Station),
    Resumed,
    WaylandGone(String),
    Note(String),
    Request(Request, Sender<Reply>),
    Watch(Sender<String>),
    /// A drawer subscribed, with an id for when it goes.
    Board(u64, Sender<String>),
    /// A drawer's socket closed.
    BoardGone(u64),
    SaverExited {
        pid: u32,
        status: String,
    },
    /// A tool's lamp line, or None when its feed ended.
    Feed(Feed, Option<LampLine>),
    /// The saver subscribed to the line.
    LineWatch(Sender<String>),
}

const TICK: Duration = Duration::from_secs(5);

/// The exit status when another daemon holds the socket (EX_TEMPFAIL).
pub const ALREADY_RUNNING: i32 = 75;

struct Daemon {
    cfg: Config,
    model: Model,
    screens: Screens,
    started: Instant,
    saver_pid: Option<u32>,
    retry_at: Option<u64>,
    watchers: Vec<Sender<String>>,
    last_lamp: Option<Lamp>,
    tx: Sender<Msg>,
    warned_no_power: bool,
    /// Drawers subscribed to snapshots (one, normally).
    boards: Vec<(u64, Sender<String>)>,
    last_snapshot: String,
    /// A show waiting for a drawer that is starting.
    pending_board: Option<String>,
    board_started: Option<Instant>,
    saver_started: Option<Instant>,
    /// Unix seconds when the daemon started, for the history's clock.
    started_wall: u64,
    rotation: Vec<&'static layover_hacks::Hack>,
    /// What each tool's lamp says, and all of it put together.
    readings: BTreeMap<Feed, Reading>,
    desk: Desk,
    /// Savers subscribed to the line, and the last update they got.
    line_watchers: Vec<Sender<String>>,
    last_line: String,
}

pub fn run(cfg: Config) -> Result<()> {
    let socket = paths::socket();
    if let Some(dir) = socket.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    if UnixStream::connect(&socket).is_ok() {
        // 75: one daemon is running, so this is not a failure to restart.
        eprintln!("layover: a daemon is already running ({})", socket.display());
        std::process::exit(ALREADY_RUNNING);
    }
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)
        .with_context(|| format!("listening on {}", socket.display()))?;

    let (tx, rx) = mpsc::channel();
    let (screens, offer) = wayland::start(&cfg, tx.clone())?;

    log(&format!("started: {}", cfg.summary()));
    if !offer.input_idle {
        log(
            "the compositor has ext-idle-notify version 1 only: every idle inhibitor holds the line, holds.ignore can't apply",
        );
    }
    if !offer.output_power {
        if cfg.line.dark_command.is_empty() {
            log(
                "the compositor has no wlr-output-power-management and line.dark_command is empty: Layover can't turn the screens off",
            );
        } else {
            log("no wlr-output-power-management: using line.dark_command and line.wake_command");
        }
    }
    for l in cfg.loosened() {
        log(&format!("looser than shipped: {l}"));
    }
    for n in cfg.notes() {
        log(&format!("note: {n}"));
    }

    spawn_listener(listener, tx.clone());
    crate::feeds::start(&cfg.feeds, &tx);
    let rotation = layover_hacks::rotation(&cfg.saver.hacks).map_err(|e| anyhow::anyhow!(e))?;
    let started_wall = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    let mut d = Daemon {
        model: Model::new(&cfg),
        cfg,
        screens,
        started: Instant::now(),
        saver_pid: None,
        retry_at: None,
        watchers: Vec::new(),
        last_lamp: None,
        tx,
        warned_no_power: false,
        boards: Vec::new(),
        last_snapshot: String::new(),
        pending_board: None,
        board_started: None,
        saver_started: None,
        started_wall,
        rotation,
        readings: BTreeMap::new(),
        desk: Desk::default(),
        line_watchers: Vec::new(),
        last_line: String::new(),
    };
    d.serve(rx)
}

impl Daemon {
    fn now(&self) -> u64 {
        self.started.elapsed().as_secs()
    }

    fn serve(&mut self, rx: Receiver<Msg>) -> Result<()> {
        let mut next_tick = Instant::now() + TICK;
        loop {
            let wait = next_tick.saturating_duration_since(Instant::now());
            match rx.recv_timeout(wait) {
                Ok(msg) => self.handle(msg)?,
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => bail!("every sender is gone"),
            }
            if Instant::now() >= next_tick {
                next_tick = Instant::now() + TICK;
                self.step(Event::Tick);
                if let Some(at) = self.retry_at
                    && self.now() >= at
                {
                    self.retry_at = None;
                    let (holds, locked) = self.read_holds();
                    self.step(Event::Retry { holds, locked });
                }
            }
            self.publish();
        }
    }

    fn handle(&mut self, msg: Msg) -> Result<()> {
        match msg {
            Msg::Idled(station) => {
                let (holds, locked) = self.read_holds();
                log(&format!("idle: {station:?} reached{}", describe_holds(&holds, locked)));
                self.step(Event::Reached { station, holds, locked });
            }
            Msg::Resumed => self.step(Event::Resumed),
            Msg::WaylandGone(e) => bail!("lost the Wayland connection: {e}"),
            Msg::Note(n) => log(&n),
            Msg::Request(req, reply) => {
                let event = match req {
                    Request::Status | Request::Watch | Request::Board | Request::Line => None,
                    Request::Hold { secs } => Some(Event::Hold { secs }),
                    Request::Release => Some(Event::Release),
                    Request::Now => Some(Event::Now),
                    Request::Stop => Some(Event::Stop),
                    Request::Toggle { anchor } => {
                        self.send_board(BoardEvent::Toggle { anchor });
                        None
                    }
                    Request::Show { anchor } => {
                        self.send_board(BoardEvent::Show { anchor });
                        None
                    }
                };
                if let Some(e) = event {
                    log(&format!("asked: {e:?}"));
                    self.step(e);
                }
                let _ = reply.send(Reply::Lamp(self.model.lamp()));
            }
            Msg::Watch(sender) => {
                if sender.send(self.model.lamp().to_line()).is_ok() {
                    self.watchers.push(sender);
                }
            }
            Msg::Board(id, sender) => {
                let snap = self.snapshot_line();
                let mut ok = sender.send(snap).is_ok();
                if let Some(p) = self.pending_board.take() {
                    ok &= sender.send(p).is_ok();
                }
                if ok {
                    self.boards.push((id, sender));
                }
            }
            Msg::BoardGone(id) => self.boards.retain(|(b, _)| *b != id),
            Msg::Feed(feed, lamp) => {
                match lamp {
                    Some(l) => {
                        self.readings.insert(feed, feeds::read(feed, &l));
                    }
                    None => {
                        self.readings.remove(&feed);
                    }
                }
                let desk = feeds::desk(&self.readings, self.cfg.feeds.cheap);
                if desk.cheap != self.desk.cheap {
                    log(&match &desk.cheap {
                        Some(why) => format!("cheap mode: {why}"),
                        None => "full rate again".into(),
                    });
                    self.step(Event::Cheap { why: desk.cheap.clone() });
                }
                self.desk = desk;
            }
            Msg::LineWatch(sender) => {
                if sender.send(self.line_update()).is_ok() {
                    self.line_watchers.push(sender);
                }
            }
            Msg::SaverExited { pid, status } => {
                if self.saver_pid == Some(pid) {
                    self.saver_pid = None;
                    self.saver_started = None;
                    log(&format!("saver exited: {status}"));
                    self.step(Event::SaverExited);
                }
            }
        }
        Ok(())
    }

    fn step(&mut self, event: Event) {
        let now = self.now();
        for effect in self.model.step(now, event) {
            self.apply(effect);
        }
    }

    fn apply(&mut self, effect: Effect) {
        match effect {
            Effect::StartSaver => self.start_saver(),
            Effect::StopSaver => {
                if let Some(pid) = self.saver_pid {
                    // SAFETY: plain signal to our own child.
                    unsafe { libc::kill(pid as i32, libc::SIGTERM) };
                }
            }
            Effect::Lock => {
                log("locking");
                spawn_detached(&self.cfg.line.lock_command, "lock");
            }
            Effect::ScreensOff => {
                log("screens off");
                self.power(false);
            }
            Effect::ScreensOn => {
                log("screens on");
                self.power(true);
            }
            Effect::Retry { after } => self.retry_at = Some(self.now() + after),
        }
    }

    fn power(&mut self, on: bool) {
        if self.screens.set(on) {
            return;
        }
        let cmd = if on { &self.cfg.line.wake_command } else { &self.cfg.line.dark_command };
        if cmd.is_empty() {
            if !self.warned_no_power {
                log("can't switch the screens: no output power management and no command set");
                self.warned_no_power = true;
            }
            return;
        }
        spawn_detached(cmd, if on { "wake" } else { "dark" });
    }

    fn start_saver(&mut self) {
        if self.saver_pid.is_some() {
            return;
        }
        let exe = match std::env::current_exe() {
            Ok(e) => e,
            Err(e) => return log(&format!("can't find my own binary to start the saver: {e}")),
        };
        let (out, err) = crate::log::child_output();
        let mut cmd = Command::new(exe);
        cmd.arg("saver").stdin(Stdio::null()).stdout(out).stderr(err);
        // SAFETY: prctl only; the saver dies with the daemon.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        match cmd.spawn() {
            Ok(mut child) => {
                let pid = child.id();
                log(&format!("saver started (pid {pid})"));
                self.saver_pid = Some(pid);
                self.saver_started = Some(Instant::now());
                let tx = self.tx.clone();
                std::thread::spawn(move || {
                    let status = match child.wait() {
                        Ok(s) => s.to_string(),
                        Err(e) => e.to_string(),
                    };
                    let _ = tx.send(Msg::SaverExited { pid, status });
                });
            }
            Err(e) => {
                log(&format!("can't start the saver: {e}"));
                self.step(Event::SaverExited);
            }
        }
    }

    fn read_holds(&self) -> (HoldSnapshot, bool) {
        let mut h = HoldSnapshot::default();
        if self.cfg.holds.inhibitors
            && let Some(json) = hyprland_request("j/clients")
        {
            match holds::inhibiting_classes(&json, &self.cfg.holds.ignore) {
                Ok(c) => h.inhibitors = c,
                Err(e) => log(&format!("reading Hyprland's clients: {e:#}")),
            }
        }
        if let Some(json) = command_output("pactl", &["-f", "json", "list", "sink-inputs"]) {
            h.audio = holds::audio_playing(&json).unwrap_or(false);
        }
        if self.cfg.holds.mic
            && let Some(json) = command_output("pactl", &["-f", "json", "list", "source-outputs"])
        {
            h.mic = holds::mic_recording(&json).unwrap_or(false);
        }
        h.on_air = self.desk.on_air;
        h.meeting_soon = self.desk.meeting_soon;
        (h, lock_running(&self.cfg.line.lock_command))
    }

    fn line_update(&self) -> String {
        let update =
            LineUpdate { rows: self.desk.rows.clone(), cheap: self.model.cheap().is_some() };
        serde_json::to_string(&update).expect("a line update is plain data")
    }

    fn publish(&mut self) {
        if !self.line_watchers.is_empty() {
            let line = self.line_update();
            if line != self.last_line {
                self.line_watchers.retain(|w| w.send(line.clone()).is_ok());
                self.last_line = line;
            }
        }
        let lamp = self.model.lamp();
        if self.last_lamp.as_ref() != Some(&lamp) {
            let line = lamp.to_line();
            self.watchers.retain(|w| w.send(line.clone()).is_ok());
            self.last_lamp = Some(lamp);
        }
        if !self.boards.is_empty() {
            let snap = self.snapshot_line();
            if snap != self.last_snapshot {
                self.boards.retain(|(_, b)| b.send(snap.clone()).is_ok());
                self.last_snapshot = snap;
            }
        }
    }

    fn snapshot_line(&self) -> String {
        let started = self.started_wall;
        let clock = move |at: u64| crate::log::clock_at(started + at);
        let hack = self.saver_started.map(|t| {
            let (h, _) =
                layover_hacks::showing(&self.rotation, &self.cfg.care, t.elapsed().as_secs_f32());
            h.name.to_string()
        });
        let hacks = layover_hacks::HACKS
            .iter()
            .map(|h| HackView {
                id: h.id.into(),
                name: h.name.into(),
                about: h.about.into(),
                in_rotation: self.rotation.iter().any(|r| r.id == h.id),
            })
            .collect();
        let snapshot = self.model.snapshot(&clock, hack, hacks);
        serde_json::to_string(&BoardEvent::Snapshot { snapshot: Box::new(snapshot) })
            .expect("a snapshot is plain data")
    }

    /// Delivers a show or toggle to the drawer, starting it when none is
    /// connected.
    fn send_board(&mut self, ev: BoardEvent) {
        let line = serde_json::to_string(&ev).expect("an event is plain data");
        self.boards.retain(|(_, b)| b.send(line.clone()).is_ok());
        if !self.boards.is_empty() {
            return;
        }
        let show = match ev {
            BoardEvent::Toggle { anchor } | BoardEvent::Show { anchor } => {
                BoardEvent::Show { anchor }
            }
            _ => return,
        };
        self.pending_board = Some(serde_json::to_string(&show).expect("an event is plain data"));
        if self.board_started.is_none_or(|t| t.elapsed() > Duration::from_secs(5)) {
            self.board_started = Some(Instant::now());
            spawn_board();
        }
    }
}

/// Starts `layover-board`, preferring the one installed next to `layover`.
fn spawn_board() {
    let local = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("layover-board")))
        .filter(|p| p.exists());
    let bin = local.map(|p| p.into_os_string()).unwrap_or_else(|| "layover-board".into());
    let mut cmd = Command::new(&bin);
    cmd.stdin(Stdio::null());
    if let Some(dir) = paths::board_log().parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(paths::board_log())
        && let Ok(f2) = f.try_clone()
    {
        cmd.stdout(f).stderr(f2);
    }
    match cmd.spawn() {
        Ok(mut child) => {
            log("drawer started");
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
        Err(e) => log(&format!("can't start {}: {e}", bin.to_string_lossy())),
    }
}

fn describe_holds(h: &HoldSnapshot, locked: bool) -> String {
    let mut parts = Vec::new();
    if !h.inhibitors.is_empty() {
        parts.push(format!("inhibitors: {}", h.inhibitors.join(", ")));
    }
    if h.audio {
        parts.push("audio playing".into());
    }
    if h.mic {
        parts.push("mic recording".into());
    }
    if h.on_air {
        parts.push("Logbook on air".into());
    }
    if h.meeting_soon {
        parts.push("meeting soon".into());
    }
    if locked {
        parts.push("locked".into());
    }
    if parts.is_empty() { String::new() } else { format!(" ({})", parts.join("; ")) }
}

/// Run a program and forget it: no death signal (a lock must outlive us)
/// and its own session.
fn spawn_detached(cmd: &[String], what: &str) {
    let Some((prog, args)) = cmd.split_first() else { return };
    let mut c = Command::new(prog);
    c.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    // SAFETY: setsid only.
    unsafe {
        c.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    match c.spawn() {
        Ok(mut child) => {
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
        Err(e) => log(&format!("can't run the {what} command `{prog}`: {e}")),
    }
}

/// Ask Hyprland's socket. None when not under Hyprland or it doesn't answer.
pub(crate) fn hyprland_request(req: &str) -> Option<String> {
    let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let path = std::path::Path::new(&runtime).join("hypr").join(sig).join(".socket.sock");
    let mut s = UnixStream::connect(path).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    s.set_write_timeout(Some(Duration::from_secs(2))).ok()?;
    s.write_all(req.as_bytes()).ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    Some(out)
}

/// A program's stdout, or None if it is missing, fails or takes over 3 s.
pub(crate) fn command_output(prog: &str, args: &[&str]) -> Option<String> {
    let mut child = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stdout.read_to_string(&mut s);
        s
    });
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return reader.join().ok(),
            Ok(Some(_)) => return None,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

/// Whether the lock program is running, by process name.
fn lock_running(lock_command: &[String]) -> bool {
    let Some(prog) = lock_command.first() else { return false };
    let name = std::path::Path::new(prog).file_name().and_then(|n| n.to_str()).unwrap_or(prog);
    let comm: String = name.chars().take(15).collect();
    let Ok(dir) = std::fs::read_dir("/proc") else { return false };
    dir.flatten().any(|e| {
        e.file_name().to_str().is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit()))
            && std::fs::read_to_string(e.path().join("comm")).is_ok_and(|c| c.trim_end() == comm)
    })
}

fn spawn_listener(listener: UnixListener, tx: Sender<Msg>) {
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let tx = tx.clone();
            std::thread::spawn(move || {
                let _ = serve_client(stream, tx);
            });
        }
    });
}

fn serve_client(stream: UnixStream, tx: Sender<Msg>) -> Result<()> {
    let mut writer = stream.try_clone()?;
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let line = line?;
        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let reply = Reply::Error { error: format!("not a request: {e}") };
                writeln!(writer, "{}", serde_json::to_string(&reply)?)?;
                continue;
            }
        };
        if req == Request::Watch || req == Request::Board || req == Request::Line {
            let (wtx, wrx) = mpsc::channel();
            if req == Request::Watch {
                tx.send(Msg::Watch(wtx))?;
            } else if req == Request::Line {
                tx.send(Msg::LineWatch(wtx))?;
            } else {
                // A subscriber that closed its socket must go at once: a
                // toggle handed to it would be lost until a write failed.
                static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                tx.send(Msg::Board(id, wtx))?;
                let mut probe = writer.try_clone()?;
                let gone = tx.clone();
                std::thread::spawn(move || {
                    let mut buf = [0u8; 256];
                    while matches!(probe.read(&mut buf), Ok(n) if n > 0) {}
                    let _ = gone.send(Msg::BoardGone(id));
                });
            }
            for lamp in wrx {
                writeln!(writer, "{lamp}")?;
                writer.flush()?;
            }
            return Ok(());
        }
        let (rtx, rrx) = mpsc::channel();
        tx.send(Msg::Request(req, rtx))?;
        let reply = rrx.recv_timeout(Duration::from_secs(5))?;
        writeln!(writer, "{}", serde_json::to_string(&reply)?)?;
    }
    Ok(())
}
