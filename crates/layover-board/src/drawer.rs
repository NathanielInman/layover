//! The drawer: the idle line now (state, why, the rail, Start and Hold),
//! the hacks with their wear numbers and a preview each, and the history
//! of what the line did and why.

use crate::anim::{Motion, Spring};
use crate::linux::load_config;
use crate::stage::Stage;
use bar_anchor::Anchor;
use gtk::prelude::*;
use gtk::{gdk, glib};
use gtk4_layer_shell::{Edge as LsEdge, KeyboardMode, Layer, LayerShell};
use layover_core::board::{BoardEvent, Snapshot};
use layover_core::config::Config;
use layover_core::lamp::MOON;
use layover_core::paths;
use layover_core::protocol::Request;
use layover_core::wear_cache::WearCache;
use std::cell::{Cell, RefCell};
use std::io::Write;
use std::rc::Rc;
use std::time::Duration;

pub enum Msg {
    Event(BoardEvent),
    /// A watched stylesheet, the config or the wear cache changed.
    Restyle,
    /// `layover wear` finished: whether it ran.
    Measured(Result<(), String>),
    /// A line for the notice: the text and whether it is an error.
    Notice(String, bool),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Tab {
    Now,
    Hacks,
    History,
}

impl Tab {
    const ALL: [Tab; 3] = [Tab::Now, Tab::Hacks, Tab::History];
    fn label(self) -> &'static str {
        match self {
            Tab::Now => "Now",
            Tab::Hacks => "Hacks",
            Tab::History => "History",
        }
    }
}

/// How long a notice stays.
const NOTICE_FOR: Duration = Duration::from_secs(4);
/// How long `Preview` shows a hack.
const PREVIEW: &str = "20s";

fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(0.0);
    for c in classes {
        l.add_css_class(c);
    }
    l
}

fn wrapped(text: &str, classes: &[&str]) -> gtk::Label {
    let l = label(text, classes);
    l.set_wrap(true);
    l.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    l
}

fn clear(b: &gtk::Box) {
    while let Some(c) = b.first_child() {
        b.remove(&c);
    }
}

fn find_monitor(name: &str) -> Option<gdk::Monitor> {
    let display = gdk::Display::default()?;
    let list = display.monitors();
    (0..list.n_items())
        .filter_map(|i| list.item(i).and_downcast::<gdk::Monitor>())
        .find(|m| m.connector().is_some_and(|c| c == name))
}

fn set_state_class(w: &impl IsA<gtk::Widget>, state: &str) {
    for c in ["armed", "held", "saver", "dark", "loose", "off"] {
        w.remove_css_class(c);
    }
    w.add_css_class(state);
}

/// `layover` next to `layover-board`, else on PATH.
fn layover_exe() -> std::ffi::OsString {
    std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("layover")))
        .filter(|p| p.exists())
        .map(|p| p.into_os_string())
        .unwrap_or_else(|| "layover".into())
}

/// Sends one request on its own thread; a missing daemon comes back as a
/// notice.
fn send_with(tx: &async_channel::Sender<Msg>, req: Request) {
    let tx = tx.clone();
    std::thread::spawn(move || {
        let sent = std::os::unix::net::UnixStream::connect(paths::socket()).and_then(|mut s| {
            writeln!(s, "{}", serde_json::to_string(&req).unwrap_or_default())?;
            let mut line = String::new();
            std::io::BufRead::read_line(&mut std::io::BufReader::new(s), &mut line)?;
            Ok(())
        });
        if sent.is_err() {
            let _ = tx.send_blocking(Msg::Notice("Layover's daemon isn't running.".into(), true));
        }
    });
}

fn percent(v: f32) -> String {
    format!("{:.1}%", v * 100.0)
}

pub struct Drawer {
    window: gtk::ApplicationWindow,
    tx: async_channel::Sender<Msg>,
    stage: Stage,
    spring: Spring,
    visible: Cell<bool>,
    snap: RefCell<Option<Snapshot>>,
    cfg: RefCell<Config>,
    tab: Cell<Tab>,
    tabs: Vec<(Tab, gtk::Button)>,
    lamp: gtk::Label,
    sub: gtk::Label,
    chip: gtk::Label,
    notice: gtk::Label,
    content: gtk::Box,
    wear: RefCell<Option<WearCache>>,
    measuring: Cell<bool>,
    message: RefCell<Option<(String, bool)>>,
    message_timer: RefCell<Option<glib::SourceId>>,
}

impl Drawer {
    pub fn new(app: &gtk::Application, tx: async_channel::Sender<Msg>, layer: bool) -> Rc<Drawer> {
        let cfg = load_config();
        let window = gtk::ApplicationWindow::new(app);
        window.add_css_class("layover");
        window.set_decorated(false);
        window.set_title(Some("Layover"));
        if layer {
            window.init_layer_shell();
            window.set_layer(Layer::Overlay);
            window.set_namespace(Some("layover"));
            for e in [LsEdge::Top, LsEdge::Bottom, LsEdge::Left, LsEdge::Right] {
                window.set_anchor(e, true);
            }
            window.set_exclusive_zone(0);
            window.set_keyboard_mode(KeyboardMode::Exclusive);
        }

        let lamp = label(MOON, &["lamp", "armed"]);
        lamp.set_valign(gtk::Align::Center);
        let brand = label("LAYOVER", &["brand"]);
        let sub = label("", &["sub"]);
        sub.set_ellipsize(gtk::pango::EllipsizeMode::End);
        let who = gtk::Box::new(gtk::Orientation::Vertical, 0);
        who.append(&brand);
        who.append(&sub);
        who.set_hexpand(true);
        let chip = label("armed", &["chip", "armed"]);
        chip.set_valign(gtk::Align::Center);
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        header.append(&lamp);
        header.append(&who);
        header.append(&chip);

        let notice = wrapped("", &["notice"]);
        notice.set_visible(false);

        let tabrow = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        tabrow.add_css_class("tabs");
        tabrow.set_homogeneous(true);
        let tabs: Vec<(Tab, gtk::Button)> = Tab::ALL
            .iter()
            .map(|t| {
                let b = gtk::Button::with_label(t.label());
                b.set_focus_on_click(false);
                tabrow.append(&b);
                (*t, b)
            })
            .collect();

        let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let scroll = gtk::ScrolledWindow::new();
        scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        scroll.set_propagate_natural_height(true);
        scroll.set_child(Some(&content));

        let foot = label(
            "1-3 tabs \u{b7} n start now \u{b7} h hold \u{b7} r release \u{b7} Esc close",
            &["foot"],
        );
        let panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        panel.add_css_class("panel");
        panel.append(&header);
        panel.append(&notice);
        panel.append(&tabrow);
        panel.append(&scroll);
        panel.append(&foot);

        let spring = Spring::new(&panel, Motion::PANEL);
        let stage = Stage::new(&spring, cfg.drawer.width, cfg.drawer.max_height, cfg.drawer.gap);
        window.set_child(Some(&stage));

        let d = Rc::new(Drawer {
            window,
            tx,
            stage,
            spring,
            visible: Cell::new(false),
            snap: RefCell::new(None),
            cfg: RefCell::new(cfg),
            tab: Cell::new(Tab::Now),
            tabs,
            lamp,
            sub,
            chip,
            notice,
            content,
            wear: RefCell::new(WearCache::load(&paths::wear_cache())),
            measuring: Cell::new(false),
            message: RefCell::new(None),
            message_timer: RefCell::new(None),
        });
        d.connect();
        d
    }

    fn connect(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        self.stage.connect_outside(move || {
            if let Some(d) = w.upgrade() {
                d.hide();
            }
        });
        let s = self.spring.clone();
        self.stage.connect_placed(move |(x, y)| s.set_origin(x, y));
        for (tab, b) in &self.tabs {
            let w = Rc::downgrade(self);
            let tab = *tab;
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    d.set_tab(tab);
                }
            });
        }
        let keys = gtk::EventControllerKey::new();
        let w = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, _| {
            let Some(d) = w.upgrade() else { return glib::Propagation::Proceed };
            d.key(key)
        });
        self.window.add_controller(keys);
    }

    pub fn handle(self: &Rc<Self>, msg: Msg) {
        match msg {
            Msg::Event(BoardEvent::Snapshot { snapshot }) => {
                *self.snap.borrow_mut() = Some(*snapshot);
                if self.visible.get() {
                    self.render();
                }
            }
            Msg::Event(BoardEvent::Show { anchor }) => self.show(anchor),
            Msg::Event(BoardEvent::Toggle { anchor }) => {
                if self.visible.get() {
                    self.hide();
                } else {
                    self.show(anchor);
                }
            }
            Msg::Event(BoardEvent::Hide) => self.hide(),
            Msg::Restyle => {
                crate::linux::apply_styles();
                let cfg = load_config();
                self.stage.set_geometry(cfg.drawer.width, cfg.drawer.max_height, cfg.drawer.gap);
                *self.cfg.borrow_mut() = cfg;
                *self.wear.borrow_mut() = WearCache::load(&paths::wear_cache());
                if self.visible.get() {
                    self.render();
                }
            }
            Msg::Measured(result) => {
                self.measuring.set(false);
                *self.wear.borrow_mut() = WearCache::load(&paths::wear_cache());
                match result {
                    Ok(()) => self.flash("Measured every hack against your budget.".into(), false),
                    Err(e) => self.flash(e, true),
                }
                if self.visible.get() {
                    self.render();
                }
            }
            Msg::Notice(text, error) => self.flash(text, error),
        }
    }

    fn send(&self, req: Request) {
        send_with(&self.tx, req);
    }

    fn flash(self: &Rc<Self>, text: String, error: bool) {
        *self.message.borrow_mut() = Some((text, error));
        if let Some(id) = self.message_timer.borrow_mut().take() {
            id.remove();
        }
        let w = Rc::downgrade(self);
        let id = glib::timeout_add_local_once(NOTICE_FOR, move || {
            let Some(d) = w.upgrade() else { return };
            d.message_timer.borrow_mut().take();
            d.message.borrow_mut().take();
            d.render_notice();
        });
        *self.message_timer.borrow_mut() = Some(id);
        self.render_notice();
    }

    fn render_notice(&self) {
        let msg = self.message.borrow().clone();
        self.notice.set_visible(msg.is_some());
        if let Some((text, error)) = msg {
            self.notice.set_label(&text);
            if error {
                self.notice.add_css_class("error");
            } else {
                self.notice.remove_css_class("error");
            }
        }
    }

    fn key(self: &Rc<Self>, key: gdk::Key) -> glib::Propagation {
        match key {
            gdk::Key::Escape => self.hide(),
            gdk::Key::_1 => self.set_tab(Tab::Now),
            gdk::Key::_2 => self.set_tab(Tab::Hacks),
            gdk::Key::_3 => self.set_tab(Tab::History),
            gdk::Key::n => self.start_now(),
            gdk::Key::h => self.send(Request::Hold { secs: 3600 }),
            gdk::Key::r => self.send(Request::Release),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    }

    /// The saver needs the screen: close the drawer first.
    fn start_now(self: &Rc<Self>) {
        self.hide();
        self.send(Request::Now);
    }

    fn show(self: &Rc<Self>, anchor: Option<Anchor>) {
        if let Some(name) = anchor.as_ref().and_then(|a| a.monitor.clone())
            && let Some(m) = find_monitor(&name)
        {
            self.window.set_monitor(Some(&m));
        }
        self.stage.set_anchor(anchor);
        let was_visible = self.visible.replace(true);
        self.render();
        self.window.set_visible(true);
        self.window.present();
        if !was_visible {
            self.spring.play_in(0);
        }
    }

    fn hide(self: &Rc<Self>) {
        if !self.visible.replace(false) {
            return;
        }
        let w = Rc::downgrade(self);
        self.spring.play_out(move || {
            if let Some(d) = w.upgrade()
                && !d.visible.get()
            {
                d.window.set_visible(false);
            }
        });
    }

    fn set_tab(self: &Rc<Self>, tab: Tab) {
        self.tab.set(tab);
        self.render();
    }

    fn render(self: &Rc<Self>) {
        let snap = self.snap.borrow().clone().unwrap_or_else(|| Snapshot {
            state: "off".into(),
            headline: "Not running".into(),
            reason: "Layover's daemon isn't running. `layover daemon` starts it.".into(),
            ..Default::default()
        });
        set_state_class(&self.lamp, &snap.state);
        set_state_class(&self.chip, &snap.state);
        self.chip.set_label(&snap.state);
        self.sub.set_label(&snap.summary);
        for (t, b) in &self.tabs {
            if *t == self.tab.get() {
                b.add_css_class("on");
            } else {
                b.remove_css_class("on");
            }
        }
        self.render_notice();
        clear(&self.content);
        match self.tab.get() {
            Tab::Now => self.render_now(&snap),
            Tab::Hacks => self.render_hacks(&snap),
            Tab::History => self.render_history(&snap),
        }
    }

    fn render_now(self: &Rc<Self>, s: &Snapshot) {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 6);
        card.add_css_class("card");
        card.add_css_class(&s.state);
        card.append(&label("THE IDLE LINE", &["t-label"]));
        card.append(&label(&s.headline, &["big", &s.state]));
        card.append(&wrapped(&s.reason, &["reason"]));
        if let Some(why) = &s.cheap {
            card.append(&wrapped(
                &format!(
                    "Cheap mode: {why}. The saver draws at half rate, half size and three quarters of the brightness."
                ),
                &["cheap"],
            ));
        }
        if let Some(h) = &s.hack {
            card.append(&label(&format!("Showing {h}"), &["showing"]));
        }

        let grid = gtk::Grid::new();
        grid.set_column_spacing(6);
        grid.set_row_spacing(6);
        grid.set_column_homogeneous(true);
        for (i, st) in s.stations.iter().enumerate() {
            let b = gtk::Box::new(gtk::Orientation::Vertical, 2);
            b.add_css_class("station");
            if !st.on {
                b.add_css_class("off");
            }
            b.append(&label(&st.name.to_uppercase(), &["name"]));
            b.append(&label(&st.at, &["at"]));
            grid.attach(&b, (i % 2) as i32, (i / 2) as i32, 1, 1);
        }
        card.append(&grid);

        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        buttons.add_css_class("buttons");
        buttons.set_margin_top(4);
        let start = gtk::Button::with_label("Start saver now");
        start.add_css_class("primary");
        start.set_sensitive(!matches!(s.state.as_str(), "saver" | "dark" | "off") && !s.locked);
        let w = Rc::downgrade(self);
        start.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.start_now();
            }
        });
        buttons.append(&start);
        let (text, req) = if s.manual_hold {
            ("Release", Request::Release)
        } else {
            ("Hold 1h", Request::Hold { secs: 3600 })
        };
        let hold = gtk::Button::with_label(text);
        hold.set_sensitive(s.state != "off");
        let w = Rc::downgrade(self);
        hold.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.send(req.clone());
            }
        });
        buttons.append(&hold);
        card.append(&buttons);
        self.content.append(&card);

        if !s.loosened.is_empty() {
            let loose = gtk::Box::new(gtk::Orientation::Vertical, 6);
            loose.add_css_class("card");
            loose.add_css_class("loose");
            loose.append(&label("LOOSER THAN SHIPPED", &["t-label", "head"]));
            for l in &s.loosened {
                loose.append(&wrapped(
                    &format!("{} = {} (shipped {})", l.key, l.value, l.shipped),
                    &["key"],
                ));
                loose.append(&wrapped(&l.why, &["why"]));
            }
            self.content.append(&loose);
        }
    }

    fn render_hacks(self: &Rc<Self>, s: &Snapshot) {
        let wear = self.wear.borrow().clone();
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let info = gtk::Box::new(gtk::Orientation::Vertical, 2);
        info.set_hexpand(true);
        info.append(&label("WEAR TEST", &["t-label"]));
        let status = match (&wear, self.measuring.get()) {
            (_, true) => "Measuring every hack, about a minute".to_string(),
            (Some(w), false) if w.measured_at > 0 => {
                format!("{} min a hack, measured {}", w.minutes, local_time(w.measured_at))
            }
            _ => "Not measured yet".to_string(),
        };
        info.append(&label(&status, &["dim"]));
        head.append(&info);
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        buttons.add_css_class("buttons");
        buttons.set_valign(gtk::Align::Center);
        let measure = gtk::Button::with_label("Measure");
        measure.set_sensitive(!self.measuring.get());
        let w = Rc::downgrade(self);
        measure.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.measure();
            }
        });
        buttons.append(&measure);
        head.append(&buttons);
        self.content.append(&head);

        for h in &s.hacks {
            let card = gtk::Box::new(gtk::Orientation::Vertical, 4);
            card.add_css_class("card");
            let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let name = label(&h.name, &["hack-name"]);
            name.set_hexpand(true);
            top.append(&name);
            if s.hack.as_deref() == Some(h.name.as_str()) {
                top.append(&label("ON SCREEN", &["showing"]));
            }
            let rot = label(
                if h.in_rotation { "in rotation" } else { "off" },
                &["rot", if h.in_rotation { "on" } else { "off" }],
            );
            rot.set_valign(gtk::Align::Center);
            top.append(&rot);
            card.append(&top);
            card.append(&wrapped(&h.about, &["about"]));

            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            match wear.as_ref().and_then(|w| w.row(&h.id)) {
                Some(r) => {
                    let numbers = label(
                        &format!(
                            "avg {} \u{b7} dwell {}s \u{b7} hottest {}",
                            percent(r.average),
                            r.max_dwell_secs,
                            percent(r.hot_spot)
                        ),
                        &["wear"],
                    );
                    numbers.set_hexpand(true);
                    row.append(&numbers);
                    if r.failures.is_empty() {
                        row.append(&label("passes", &["pass"]));
                    } else {
                        row.append(&label("fails", &["fail"]));
                    }
                }
                None => {
                    let none = label("not measured", &["wear", "dim"]);
                    none.set_hexpand(true);
                    row.append(&none);
                }
            }
            let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            buttons.add_css_class("buttons");
            let preview = gtk::Button::with_label("Preview");
            let w = Rc::downgrade(self);
            let id = h.id.clone();
            preview.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    d.preview(&id);
                }
            });
            buttons.append(&preview);
            row.append(&buttons);
            card.append(&row);
            if let Some(r) = wear.as_ref().and_then(|w| w.row(&h.id)) {
                for f in &r.failures {
                    card.append(&wrapped(f, &["why"]));
                }
            }
            self.content.append(&card);
        }
    }

    fn render_history(self: &Rc<Self>, s: &Snapshot) {
        if s.history.is_empty() {
            let card = gtk::Box::new(gtk::Orientation::Vertical, 4);
            card.add_css_class("card");
            card.append(&wrapped(
                "Nothing yet. Every saver, hold, lock and screens off shows up here with why.",
                &["dim"],
            ));
            self.content.append(&card);
            return;
        }
        let card = gtk::Box::new(gtk::Orientation::Vertical, 8);
        card.add_css_class("card");
        for e in &s.history {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
            let time = label(&e.time, &["hist-time"]);
            time.set_valign(gtk::Align::Start);
            row.append(&time);
            let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
            text.set_hexpand(true);
            text.append(&wrapped(&e.what, &["hist-what"]));
            if !e.why.is_empty() {
                text.append(&wrapped(&e.why, &["hist-why"]));
            }
            row.append(&text);
            card.append(&row);
        }
        self.content.append(&card);
    }

    /// Runs `layover wear` off the main thread; the cache it writes comes
    /// back through the file watch and `Msg::Measured`.
    fn measure(self: &Rc<Self>) {
        if self.measuring.replace(true) {
            return;
        }
        self.render();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = std::process::Command::new(layover_exe())
                .args(["wear", "--minutes", "60"])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped())
                .output();
            let msg = match result {
                Ok(o) if o.status.success() || o.status.code() == Some(1) => Ok(()),
                Ok(o) => Err(format!(
                    "The wear test didn't run: {}",
                    String::from_utf8_lossy(&o.stderr).lines().last().unwrap_or("it failed")
                )),
                Err(e) => Err(format!("Couldn't run layover wear: {e}")),
            };
            let _ = tx.send_blocking(Msg::Measured(msg));
        });
    }

    /// Closes the drawer and shows one hack for a while.
    fn preview(self: &Rc<Self>, id: &str) {
        self.hide();
        let id = id.to_string();
        let tx = self.tx.clone();
        // Let the drawer's close animation finish first.
        glib::timeout_add_local_once(Duration::from_millis(250), move || {
            match std::process::Command::new(layover_exe())
                .args(["saver", "--hack", &id, "--for", PREVIEW])
                .stdin(std::process::Stdio::null())
                .spawn()
            {
                Ok(mut child) => {
                    std::thread::spawn(move || {
                        let _ = child.wait();
                    });
                }
                Err(e) => {
                    let _ = tx.send_blocking(Msg::Notice(
                        format!("Couldn't start the preview: {e}"),
                        true,
                    ));
                }
            }
        });
    }

    /// Draws the panel for `snap` on `tab` into a PNG, then quits.
    pub fn shoot(
        self: &Rc<Self>,
        out: String,
        snap: Option<Snapshot>,
        tab: Option<String>,
        app: gtk::Application,
    ) {
        *self.snap.borrow_mut() = snap;
        let tab = match tab.as_deref() {
            Some("hacks") => Tab::Hacks,
            Some("history") => Tab::History,
            _ => Tab::Now,
        };
        self.tab.set(tab);
        // No layer surface here: give the window room for the panel.
        let width = self.cfg.borrow().drawer.width as i32 + 48;
        self.window.set_default_size(width, 980);
        self.show(None);
        let d = self.clone();
        glib::timeout_add_local_once(Duration::from_millis(1200), move || {
            d.spring.settle();
            let tries = Rc::new(Cell::new(0));
            glib::timeout_add_local(Duration::from_millis(100), move || {
                let widget: gtk::Widget = d.spring.clone().upcast();
                let (wd, ht) = (widget.width(), widget.height());
                let paintable = gtk::WidgetPaintable::new(Some(&widget));
                let snapshot = gtk::Snapshot::new();
                paintable.snapshot(&snapshot, wd as f64, ht as f64);
                tries.set(tries.get() + 1);
                match (snapshot.to_node(), widget.native().and_then(|n| n.renderer())) {
                    (Some(node), Some(renderer)) => {
                        let tex = renderer.render_texture(&node, None);
                        match tex.save_to_png(&out) {
                            Ok(()) => println!("{out} {wd}x{ht}"),
                            Err(e) => eprintln!("layover-board: {e}"),
                        }
                    }
                    _ if tries.get() < 50 => return glib::ControlFlow::Continue,
                    _ => eprintln!("layover-board: nothing to draw ({wd}x{ht})"),
                }
                app.quit();
                glib::ControlFlow::Break
            });
        });
    }
}

/// Local time of a Unix second as `14:02`.
pub fn local_time(unix: u64) -> String {
    glib::DateTime::from_unix_local(unix as i64)
        .ok()
        .and_then(|d| d.format("%H:%M").ok())
        .map(|s| s.to_string())
        .unwrap_or_default()
}
