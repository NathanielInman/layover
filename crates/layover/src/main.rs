//! `layover`: the daemon, the saver, the waybar module and the CLI.

mod saver;

use anyhow::{Context, Result, anyhow, bail};
use layover_core::config::{Concern, Config};
use layover_core::paths;
use layover_core::span::parse_duration;
use layover_hacks::wear::{self, Budget};
use layover_hacks::{HACKS, renderer::CareSettings};
use std::path::PathBuf;

const USAGE: &str = "\
layover: a screensaver for Wayland that looks after your monitor

Usage:
  layover check                  check the config and list every value looser than shipped
  layover hacks                  list the hacks
  layover saver [--hack <id>]... [--for <duration>]
                                 show hacks now, without the daemon
  layover wear [<id>...] [--minutes <n>] [--out <dir>]
                                 run the wear test against your config and write heat maps
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
        "saver" => saver_cmd(rest),
        "check" => check(),
        "hacks" => {
            let cfg = load_config().unwrap_or_default();
            let on: Vec<&str> = layover_hacks::rotation(&cfg.saver.hacks)
                .unwrap_or_default()
                .iter()
                .map(|h| h.id)
                .collect();
            for h in HACKS {
                let mark = if on.contains(&h.id) { "*" } else { " " };
                println!("{mark} {:<14} {}", h.id, h.about);
            }
            Ok(0)
        }
        "wear" => wear_cmd(rest),
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
    if let Err(e) = layover_hacks::rotation(&cfg.saver.hacks) {
        println!("[saver] hacks: {e}");
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
    let ids = if ids.is_empty() { cfg.saver.hacks.clone() } else { ids };
    let hacks = layover_hacks::rotation(&ids).map_err(|e| anyhow!(e))?;
    saver::run(&cfg, saver::Options { hacks, run_for })?;
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
    for hack in hacks {
        let report = wear::run(&gpu, hack, &care, minutes * 60, [256, 72], wear::G9_CANVAS)?;
        let png = out.join(format!("{}.png", hack.id));
        report.write_heat_png(&png, 4)?;
        let f = report.failures(&budget);
        println!("{}", report.summary());
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
    Ok(if failed > 0 { 1 } else { 0 })
}
