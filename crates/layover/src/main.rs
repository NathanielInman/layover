//! `layover`: the daemon, the saver, the waybar module and the CLI.

mod daemon;
mod doctor;
mod feeds;
mod log;
mod saver;
mod wayland;

use anyhow::{Context, Result, anyhow, bail};
use layover_core::config::{Concern, Config, Weight};
use layover_core::config_edit;
use layover_core::lamp::Lamp;
use layover_core::paths;
use layover_core::protocol::{Reply, Request};
use layover_core::span::parse_duration;
use layover_hacks::wear::{self, Budget};
use layover_hacks::{HACKS, renderer::CareSettings};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const USAGE: &str = "\
layover: a screensaver for Wayland that looks after your monitor

Usage:
  layover daemon                 run the idle line (start it from your compositor)
  layover bar                    the waybar module: one JSON line per change
  layover toggle [--center]      open or close the drawer from the clicked moon
  layover show [--center]        open the drawer
  layover status                 what the idle line is doing, and why
  layover now                    start the saver now
  layover stop                   stop the saver
  layover hold <duration>        hold the saver, the lock and the dark (\"1h\", \"30m\")
  layover release                end a hold
  layover check                  check the config and list every value looser than shipped
  layover doctor                 check the setup: the daemon, the compositor, Vulkan,
                                 pactl, the lock, waybar and the drawer
  layover hacks                  list the hacks (* in the rotation, ** starred)
  layover rotation <id> never|sometimes|often
                                 take a hack out of the rotation, put it back, or star it
  layover saver [--hack <id>]... [--for <duration>]
                                 show hacks now, without the daemon
  layover wear [<id>...] [--minutes <n>] [--out <dir>]
                                 run the wear test against your config and write heat maps
  layover thumbs [<id>...] [--force]
                                 draw the drawer's thumbnails (only stale ones unless --force)
  layover --version

The config is ~/.config/layover/layover.toml; `layover check` explains it.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match run(&args) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("layover: {e:#}");
            2
        }
    };
    std::process::exit(code);
}

fn load_config() -> Result<Config> {
    Config::load(&paths::config_file())
}

fn run(args: &[String]) -> Result<i32> {
    let Some(cmd) = args.first() else {
        print!("{USAGE}");
        return Ok(0);
    };
    let rest = &args[1..];
    match cmd.as_str() {
        "daemon" => {
            let cfg = load_config()?;
            layover_hacks::run_order(&cfg.saver).map_err(|e| anyhow!("[saver] {e}"))?;
            daemon::run(cfg)?;
            Ok(0)
        }
        "saver" => saver_cmd(rest),
        "bar" => bar(),
        "status" => {
            match ask(&Request::Status) {
                Ok(lamp) => println!("{}", lamp.tooltip),
                Err(_) => println!("{}", Lamp::off().tooltip),
            }
            Ok(0)
        }
        cmd @ ("toggle" | "show") => {
            let cfg = load_config().unwrap_or_default();
            // Ask the compositor first: the cursor is still on the icon.
            let hint = layover_core::waybar::load_layout().unwrap_or_default().hint();
            let center = rest.iter().any(|a| a == "--center");
            let anchor = bar_anchor::anchor(&cfg.bar.namespace, hint, center);
            ask(&if cmd == "toggle" {
                Request::Toggle { anchor }
            } else {
                Request::Show { anchor }
            })?;
            Ok(0)
        }
        "now" => print_reply(ask(&Request::Now)?),
        "stop" => print_reply(ask(&Request::Stop)?),
        "release" => print_reply(ask(&Request::Release)?),
        "hold" => {
            let d = rest.first().ok_or_else(|| anyhow!("hold how long? e.g. `layover hold 1h`"))?;
            let secs = parse_duration(d).map_err(|e| anyhow!(e))?.as_secs();
            print_reply(ask(&Request::Hold { secs })?)
        }
        "check" => check(),
        "doctor" => {
            let checks = doctor::checks();
            for c in &checks {
                println!("{}", c.line());
            }
            Ok(if layover_core::doctor::failed(&checks) { 1 } else { 0 })
        }
        "hacks" => {
            let cfg = load_config().unwrap_or_default();
            for h in HACKS {
                let mark = match cfg.saver.weight(h.id) {
                    Weight::Never => " ",
                    Weight::Sometimes => "*",
                    Weight::Often => "**",
                };
                println!("{mark:<2} {:<16} {}", h.id, h.about);
            }
            Ok(0)
        }
        "rotation" => rotation_cmd(rest),
        "wear" => wear_cmd(rest),
        "thumbs" => thumbs_cmd(rest),
        "-V" | "--version" | "version" => {
            println!("layover {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            Ok(0)
        }
        other => bail!("no command `{other}` (`layover help` lists them)"),
    }
}

fn print_reply(lamp: Lamp) -> Result<i32> {
    println!("{}", lamp.tooltip);
    Ok(0)
}

fn connect() -> Result<UnixStream> {
    UnixStream::connect(paths::socket())
        .context("Layover's daemon isn't running (`layover daemon` starts it)")
}

fn ask(req: &Request) -> Result<Lamp> {
    let mut s = connect()?;
    s.set_read_timeout(Some(Duration::from_secs(6)))?;
    writeln!(s, "{}", serde_json::to_string(req)?)?;
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line)?;
    match serde_json::from_str::<Reply>(&line).context("the daemon's answer isn't a reply")? {
        Reply::Lamp(l) => Ok(l),
        Reply::Error { error } => bail!(error),
    }
}

/// The waybar module: print the lamp on every change, and the off lamp
/// (then try again) whenever the daemon is gone.
fn bar() -> Result<i32> {
    let mut out = std::io::stdout().lock();
    let mut shown_off = false;
    loop {
        if let Ok(mut s) = connect()
            && writeln!(s, "{}", serde_json::to_string(&Request::Watch)?).is_ok()
        {
            shown_off = false;
            for line in BufReader::new(s).lines() {
                let Ok(line) = line else { break };
                writeln!(out, "{line}")?;
                out.flush()?;
            }
        }
        if !shown_off {
            writeln!(out, "{}", Lamp::off().to_line())?;
            out.flush()?;
            shown_off = true;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn check() -> Result<i32> {
    let path = paths::config_file();
    let cfg = match Config::load(&path) {
        Ok(c) => c,
        Err(e) => {
            println!("{}: {e:#}", path.display());
            return Ok(1);
        }
    };
    println!(
        "{}",
        if path.exists() {
            path.display().to_string()
        } else {
            format!("{} (not found: shipped defaults)", path.display())
        }
    );
    println!("{}", cfg.summary());
    if let Err(e) = layover_hacks::run_order(&cfg.saver) {
        println!("[saver] {e}");
        return Ok(1);
    }
    for n in cfg.notes() {
        println!("note: {n}");
    }
    let loose = cfg.loosened();
    if loose.is_empty() {
        println!("Every limit is at or inside the shipped value.");
        return Ok(0);
    }
    for (concern, title) in
        [(Concern::Panel, "puts your monitor at risk"), (Concern::Power, "costs power")]
    {
        let group: Vec<_> = loose.iter().filter(|l| l.concern == concern).collect();
        if group.is_empty() {
            continue;
        }
        println!("\nLooser than shipped, {title}:");
        for l in group {
            println!("  {} = {} (shipped {})\n    {}", l.key, l.value, l.shipped, l.why);
        }
    }
    Ok(0)
}

/// `layover rotation <id> <weight>`: through the daemon, so its rotation
/// changes at once; straight into the config when no daemon runs.
fn rotation_cmd(rest: &[String]) -> Result<i32> {
    let [id, weight] = rest else {
        bail!("usage: layover rotation <id> never|sometimes|often");
    };
    let weight: Weight = weight.parse().map_err(|e: String| anyhow!(e))?;
    if layover_hacks::find(id).is_none() {
        bail!("no hack called `{id}` (`layover hacks` lists them)");
    }
    let req = Request::Rotation { hack: id.clone(), weight };
    if connect().is_ok() {
        ask(&req)?;
    } else {
        let path = paths::config_file();
        let (text, cfg) = config_edit::plan_weight(&path, id, weight)?;
        layover_hacks::run_order(&cfg.saver).map_err(|e| anyhow!(e))?;
        config_edit::write(&path, &text)?;
    }
    println!(
        "{id}: {}",
        match weight {
            Weight::Never => "out of the rotation",
            Weight::Sometimes => "in the rotation",
            Weight::Often => "starred, twice a round",
        }
    );
    Ok(0)
}

fn saver_cmd(rest: &[String]) -> Result<i32> {
    let cfg = load_config()?;
    let mut ids = Vec::new();
    let mut run_for = None;
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--hack" => ids.push(it.next().ok_or_else(|| anyhow!("--hack needs an id"))?.clone()),
            "--for" => {
                let d = it.next().ok_or_else(|| anyhow!("--for needs a duration"))?;
                run_for = Some(parse_duration(d).map_err(|e| anyhow!(e))?);
            }
            other => bail!("unknown option `{other}`"),
        }
    }
    let hacks = if ids.is_empty() {
        layover_hacks::run_order(&cfg.saver)
    } else {
        layover_hacks::rotation(&ids)
    }
    .map_err(|e| anyhow!(e))?;
    saver::run(&cfg, saver::Options { hacks, run_for })?;
    Ok(0)
}

/// Thumbnails this wide, in pixels.
const THUMB_WIDTH: u32 = 384;

/// `layover thumbs`: draws each hack's pictures for the drawer into the
/// cache, skipping ones already drawn from the same shader and canvas.
fn thumbs_cmd(rest: &[String]) -> Result<i32> {
    use layover_core::thumbs::{Shot, ThumbIndex, canvas_from_hyprland, size_for};
    use layover_hacks::thumbs;
    let cfg = load_config()?;
    let force = rest.iter().any(|a| a == "--force");
    let ids: Vec<String> = rest.iter().filter(|a| !a.starts_with("--")).cloned().collect();
    let hacks = layover_hacks::rotation(&ids).map_err(|e| anyhow!(e))?;
    let canvas = daemon::hyprland_request("j/monitors")
        .and_then(|j| canvas_from_hyprland(&j))
        .unwrap_or([2560.0, 1440.0]);
    let size = size_for(canvas, THUMB_WIDTH);
    let dir = paths::thumbs_dir();
    let mut index = ThumbIndex::load(&dir).unwrap_or_default();
    if index.canvas != canvas || index.size != size {
        index = ThumbIndex { canvas, size, ..Default::default() };
    }
    index.loop_frames = thumbs::LOOP_FRAMES;
    index.loop_fps = thumbs::LOOP_FPS;
    let todo: Vec<_> = hacks
        .into_iter()
        .filter(|h| force || !index.fresh(&dir, h.id, &thumbs::key(h, canvas, size)))
        .collect();
    if todo.is_empty() {
        println!("every thumbnail is up to date ({})", dir.display());
        return Ok(0);
    }
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let gpu = layover_hacks::gpu::Gpu::headless()?;
    let care = CareSettings::from_config(&cfg.care);
    for hack in todo {
        let t = thumbs::render(&gpu, hack, &care, size, canvas)?;
        for (shot, data) in
            [(Shot::Early, &t.early), (Shot::Still, &t.still), (Shot::Loop, &t.strip)]
        {
            thumbs::write_png(&ThumbIndex::file(&dir, hack.id, shot), data, size[0])?;
        }
        index.hacks.insert(hack.id.into(), thumbs::key(hack, canvas, size));
        // Saved after each hack, so the drawer fills in as they come.
        index.save(&dir)?;
        println!("{}", hack.id);
    }
    Ok(0)
}

fn wear_cmd(rest: &[String]) -> Result<i32> {
    let cfg = load_config()?;
    let mut ids = Vec::new();
    let mut minutes = 60u32;
    let mut out = paths::state_dir().join("wear");
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--minutes" => {
                minutes = it.next().ok_or_else(|| anyhow!("--minutes needs a number"))?.parse()?
            }
            "--out" => {
                out = PathBuf::from(it.next().ok_or_else(|| anyhow!("--out needs a directory"))?)
            }
            id => ids.push(id.to_string()),
        }
    }
    let hacks = layover_hacks::rotation(&ids).map_err(|e| anyhow!(e))?;
    std::fs::create_dir_all(&out).with_context(|| format!("creating {}", out.display()))?;
    let gpu = layover_hacks::gpu::Gpu::headless()?;
    let care = CareSettings::from_config(&cfg.care);
    let budget = Budget::from_care(&cfg.care);
    let mut failed = 0;
    let mut cache =
        layover_core::wear_cache::WearCache::load(&paths::wear_cache()).unwrap_or_default();
    cache.minutes = minutes;
    for hack in hacks {
        let report = wear::run(&gpu, hack, &care, minutes * 60, [256, 72], wear::G9_CANVAS)?;
        let png = out.join(format!("{}.png", hack.id));
        report.write_heat_png(&png, 4)?;
        let f = report.failures(&budget);
        println!("{}", report.summary());
        cache.hacks.retain(|r| r.id != hack.id);
        cache.hacks.push(layover_core::wear_cache::WearRow {
            id: hack.id.into(),
            average: report.average,
            max_dwell_secs: report.max_dwell_secs,
            hot_spot: report.hot_spot,
            share: report.share,
            peak: report.peak,
            failures: f.clone(),
        });
        if f.is_empty() {
            println!("  passes · heat map {}", png.display());
        } else {
            failed += 1;
            for line in f {
                println!("  FAILS: {line}");
            }
            println!("  heat map {}", png.display());
        }
    }
    cache.measured_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    cache.save(&paths::wear_cache())?;
    Ok(if failed > 0 { 1 } else { 0 })
}
