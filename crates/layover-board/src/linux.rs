//! Startup: styles, the daemon subscription, and file watches that restyle
//! the drawer when the bar's stylesheet or Layover's config changes.

use crate::drawer::{Drawer, Msg};
use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use layover_core::board::BoardEvent;
use layover_core::config::Config;
use layover_core::paths;
use std::cell::RefCell;
use std::io::{BufRead, BufReader, Write};
use std::time::Duration;

const DEFAULT_CSS: &str = include_str!("style.css");

thread_local! {
    static THEME: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
    static USER: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
    static WATCHES: RefCell<Vec<gio::FileMonitor>> = const { RefCell::new(Vec::new()) };
}

fn provider(
    slot: &'static std::thread::LocalKey<RefCell<Option<gtk::CssProvider>>>,
    priority: u32,
) -> Option<gtk::CssProvider> {
    let display = gdk::Display::default()?;
    Some(slot.with(|s| {
        s.borrow_mut()
            .get_or_insert_with(|| {
                let p = gtk::CssProvider::new();
                gtk::style_context_add_provider_for_display(&display, &p, priority);
                p
            })
            .clone()
    }))
}

pub fn load_config() -> Config {
    Config::load(&paths::config_file()).unwrap_or_default()
}

/// Applies the theme layers in order: built-in, the bar's look, the user's
/// own stylesheet.
pub fn apply_styles() {
    let cfg = load_config();
    if let Some(p) = provider(&THEME, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1) {
        let bar = layover_core::waybar::load_theme();
        p.load_from_string(&crate::theme::css(bar.as_ref(), &cfg));
    }
    if let Some(p) = provider(&USER, gtk::STYLE_PROVIDER_PRIORITY_USER) {
        let user = std::fs::read_to_string(paths::style_file()).unwrap_or_default();
        p.load_from_string(&user);
    }
}

fn watch(path: std::path::PathBuf, on_change: impl Fn() + 'static) {
    let file = gio::File::for_path(&path);
    if let Ok(m) = file.monitor_file(gio::FileMonitorFlags::NONE, gio::Cancellable::NONE) {
        m.connect_changed(move |_, _, _, ev| {
            if matches!(
                ev,
                gio::FileMonitorEvent::ChangesDoneHint
                    | gio::FileMonitorEvent::Created
                    | gio::FileMonitorEvent::Deleted
            ) {
                on_change();
            }
        });
        WATCHES.with(|w| w.borrow_mut().push(m));
    }
}

/// Keeps a subscription to the daemon open, reconnecting forever.
fn connection(tx: async_channel::Sender<Msg>) {
    loop {
        if let Ok(mut s) = std::os::unix::net::UnixStream::connect(paths::socket())
            && writeln!(s, "{{\"cmd\":\"board\"}}").is_ok()
        {
            for line in BufReader::new(s).lines() {
                let Ok(line) = line else { break };
                match serde_json::from_str::<BoardEvent>(&line) {
                    Ok(ev) => {
                        if tx.send_blocking(Msg::Event(ev)).is_err() {
                            return;
                        }
                    }
                    Err(e) => eprintln!("layover-board: not an event: {e}"),
                }
            }
        }
        std::thread::sleep(Duration::from_millis(800));
    }
}

pub fn main() -> glib::ExitCode {
    if std::env::args().any(|a| a == "--version" || a == "-V") {
        println!("layover-board {}", env!("CARGO_PKG_VERSION"));
        return glib::ExitCode::SUCCESS;
    }
    let app = gtk::Application::builder()
        .application_id("io.github.nathanielinman.Layover")
        // The daemon decides when a drawer starts; a second one (a dev build)
        // must not hand itself to the first over D-Bus.
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    // `--shot <png> <snapshot.json> [now|hacks|hacks-list|sheet:<id>|history]`:
    // draws the panel for
    // a saved snapshot into a PNG and exits, without a layer surface.
    let args: Vec<String> = std::env::args().collect();
    let shot = args.iter().position(|a| a == "--shot").map(|i| args[i + 1..].to_vec());
    let built = std::rc::Rc::new(std::cell::Cell::new(false));
    app.connect_activate(move |app| {
        if built.replace(true) {
            return;
        }
        if shot.is_none() && !gtk4_layer_shell::is_supported() {
            eprintln!("layover-board: this compositor does not support wlr-layer-shell");
        }
        if let Some(display) = gdk::Display::default() {
            let base = gtk::CssProvider::new();
            base.load_from_string(DEFAULT_CSS);
            gtk::style_context_add_provider_for_display(
                &display,
                &base,
                gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }
        apply_styles();
        let (tx, rx) = async_channel::unbounded::<Msg>();
        // One drawer open at a time across the apps: another app's drawer
        // opening closes this one.
        let drawers = {
            let tx = tx.clone();
            bar_anchor::drawers::listen("layover", move || {
                let _ = tx.send_blocking(Msg::OtherDrawerOpened);
            })
            .inspect_err(|e| eprintln!("layover-board: {e}"))
            .ok()
        };
        let drawer = Drawer::new(app, tx.clone(), shot.is_none());
        if let Some(a) = &shot {
            let out = a.first().cloned().unwrap_or_else(|| "layover-board.png".into());
            let snap = a
                .get(1)
                .and_then(|f| std::fs::read_to_string(f).ok())
                .and_then(|t| serde_json::from_str(&t).ok());
            drawer.shoot(out, snap, a.get(2).cloned(), app.clone());
            return;
        }
        for path in [
            layover_core::waybar::style_path(),
            paths::style_file(),
            paths::config_file(),
            paths::wear_cache(),
        ] {
            let tx = tx.clone();
            watch(path, move || {
                let _ = tx.send_blocking(Msg::Restyle);
            });
        }
        {
            let tx = tx.clone();
            let index = layover_core::thumbs::ThumbIndex::path(&paths::thumbs_dir());
            watch(index, move || {
                let _ = tx.send_blocking(Msg::ThumbsChanged);
            });
        }
        std::mem::forget(app.hold());
        std::thread::spawn(move || connection(tx));
        glib::spawn_future_local(async move {
            let _drawers = drawers;
            while let Ok(msg) = rx.recv().await {
                drawer.handle(msg);
            }
        });
    });
    app.run_with_args::<&str>(&[])
}
