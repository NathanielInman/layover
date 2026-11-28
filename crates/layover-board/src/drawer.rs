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
use layover_core::protocol::{Reply, Request};
use layover_core::wear_cache::WearCache;
use std::cell::{Cell, RefCell};
use std::io::Write;
use std::rc::Rc;
use std::time::Duration;

pub enum Msg {
    /// Another app's drawer opened: close this one.
    OtherDrawerOpened,
    Event(BoardEvent),
    /// A watched stylesheet, the config or the wear cache changed.
    Restyle,
    /// `layover wear` finished: whether it ran.
    Measured(Result<(), String>),
    /// A line for the notice: the text and whether it is an error.
    Notice(String, bool),
    /// `layover thumbs` wrote its index: load the new pictures.
    ThumbsChanged,
    /// `layover thumbs` finished, with why it failed if it did.
    ThumbsDone(Option<String>),
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

/// What a quick menu item does.
type MenuAction = Box<dyn Fn(&Rc<Drawer>)>;

/// The quick menu's width.
const MENU_WIDTH: f64 = 300.0;

/// How long a notice stays.
const NOTICE_FOR: Duration = Duration::from_secs(4);
/// How long `Preview` shows a hack.
const PREVIEW: &str = "20s";

pub(crate) fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(0.0);
    for c in classes {
        l.add_css_class(c);
    }
    l
}

pub(crate) fn wrapped(text: &str, classes: &[&str]) -> gtk::Label {
    let l = label(text, classes);
    l.set_wrap(true);
    l.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    l
}

pub(crate) fn clear(b: &gtk::Box) {
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
pub(crate) fn layover_exe() -> std::ffi::OsString {
    std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("layover")))
        .filter(|p| p.exists())
        .map(|p| p.into_os_string())
        .unwrap_or_else(|| "layover".into())
}

/// Sends one request on its own thread; a missing daemon or a refusal
/// comes back as a notice.
fn send_with(tx: &async_channel::Sender<Msg>, req: Request) {
    let tx = tx.clone();
    std::thread::spawn(move || {
        let sent = std::os::unix::net::UnixStream::connect(paths::socket()).and_then(|mut s| {
            writeln!(s, "{}", serde_json::to_string(&req).unwrap_or_default())?;
            let mut line = String::new();
            std::io::BufRead::read_line(&mut std::io::BufReader::new(s), &mut line)?;
            Ok(line)
        });
        let notice = match sent {
            Err(_) => Some("Layover's daemon isn't running.".to_string()),
            Ok(line) => match serde_json::from_str::<Reply>(&line) {
                Ok(Reply::Error { error }) => Some(error),
                _ => None,
            },
        };
        if let Some(n) = notice {
            let _ = tx.send_blocking(Msg::Notice(n, true));
        }
    });
}

pub struct Drawer {
    pub(crate) window: gtk::ApplicationWindow,
    pub(crate) tx: async_channel::Sender<Msg>,
    stage: Stage,
    spring: Spring,
    visible: Cell<bool>,
    pub(crate) snap: RefCell<Option<Snapshot>>,
    pub(crate) cfg: RefCell<Config>,
    tab: Cell<Tab>,
    tabs: Vec<(Tab, gtk::Button)>,
    lamp: gtk::Label,
    sub: gtk::Label,
    chip: gtk::Label,
    notice: gtk::Label,
    pub(crate) content: gtk::Box,
    pub(crate) wear: RefCell<Option<WearCache>>,
    pub(crate) measuring: Cell<bool>,
    message: RefCell<Option<(String, bool)>>,
    message_timer: RefCell<Option<glib::SourceId>>,
    /// What the content was last drawn from: a render that would draw the
    /// same thing leaves it (and its scroll, focus and hover) alone.
    rendered: RefCell<String>,
    pub(crate) thumbs: Rc<RefCell<crate::thumbs::Store>>,
    /// Bumped when the thumbnails change, so a render redraws them.
    thumbs_gen: Cell<u32>,
    pub(crate) thumbs_started: Cell<bool>,
    /// Drawing a screenshot with `--shot`: start nothing.
    pub(crate) shooting: Cell<bool>,
    pub(crate) hacks_ui: RefCell<Option<Rc<crate::hacks::HacksUi>>>,
    pub(crate) hacks_filter: RefCell<crate::hacks::Filter>,
    pub(crate) hacks_query: RefCell<String>,
    /// The gallery as compact rows instead of strips.
    pub(crate) hacks_rows: Cell<bool>,
    /// The hack whose sheet is open.
    pub(crate) sheet: RefCell<Option<String>>,
    /// Open as the quick menu: small, no header, tabs or keys line.
    menu: Cell<bool>,
    /// The header, tabs and keys line, hidden in the quick menu.
    chrome: Vec<gtk::Widget>,
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
            "1-3 tabs \u{b7} n start \u{b7} h hold \u{b7} + \u{2212} longer/shorter \u{b7} r release \u{b7} Esc",
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
            rendered: RefCell::new(String::new()),
            thumbs: Rc::new(RefCell::new(crate::thumbs::Store::new())),
            thumbs_gen: Cell::new(0),
            thumbs_started: Cell::new(false),
            shooting: Cell::new(false),
            hacks_ui: RefCell::new(None),
            hacks_filter: RefCell::new(crate::hacks::Filter::All),
            hacks_query: RefCell::new(String::new()),
            hacks_rows: Cell::new(false),
            sheet: RefCell::new(None),
            menu: Cell::new(false),
            chrome: vec![header.upcast(), tabrow.upcast(), foot.upcast()],
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
            Msg::OtherDrawerOpened => self.hide(),
            Msg::Event(BoardEvent::Snapshot { snapshot }) => {
                *self.snap.borrow_mut() = Some(*snapshot);
                if self.visible.get() {
                    self.render();
                }
            }
            Msg::Event(BoardEvent::Show { anchor }) => self.show(anchor),
            Msg::Event(BoardEvent::Toggle { anchor }) => {
                if self.visible.get() && !self.menu.get() {
                    self.hide();
                } else {
                    self.show(anchor);
                }
            }
            Msg::Event(BoardEvent::Menu { anchor }) => {
                if self.visible.get() && self.menu.get() {
                    self.hide();
                } else {
                    self.show_menu(anchor);
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
                    Ok(()) => self.flash("Measured against your budget.".into(), false),
                    Err(e) => self.flash(e, true),
                }
                if self.visible.get() {
                    self.render();
                }
            }
            Msg::Notice(text, error) => self.flash(text, error),
            Msg::ThumbsChanged => {
                self.thumbs.borrow_mut().reload();
                self.thumbs_gen.set(self.thumbs_gen.get() + 1);
                if self.visible.get() {
                    self.render();
                }
            }
            Msg::ThumbsDone(err) => {
                if let Some(e) = err {
                    self.flash(e, true);
                }
            }
        }
    }

    pub(crate) fn send(&self, req: Request) {
        send_with(&self.tx, req);
    }

    pub(crate) fn flash(self: &Rc<Self>, text: String, error: bool) {
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
        if self.menu.get() {
            match key {
                gdk::Key::Escape => self.hide(),
                gdk::Key::n => self.start_now(),
                gdk::Key::a => self.audition(None),
                gdk::Key::o => self.show(None),
                gdk::Key::r => {
                    self.send(Request::Release);
                    self.hide();
                }
                gdk::Key::h => {
                    self.send(Request::Hold { secs: 3600 });
                    self.hide();
                }
                _ => return glib::Propagation::Proceed,
            }
            return glib::Propagation::Stop;
        }
        if self.tab.get() == Tab::Hacks && self.sheet_key(key) {
            return glib::Propagation::Stop;
        }
        match key {
            gdk::Key::a if self.tab.get() == Tab::Hacks => self.audition(None),
            gdk::Key::slash if self.tab.get() == Tab::Hacks => {
                if let Some(ui) = self.hacks_ui.borrow().as_ref() {
                    ui.search.grab_focus();
                }
            }
            gdk::Key::Escape => self.hide(),
            gdk::Key::_1 => self.set_tab(Tab::Now),
            gdk::Key::_2 => self.set_tab(Tab::Hacks),
            gdk::Key::_3 => self.set_tab(Tab::History),
            gdk::Key::n => self.start_now(),
            gdk::Key::h => self.send(Request::Hold { secs: 3600 }),
            gdk::Key::plus | gdk::Key::equal | gdk::Key::KP_Add => {
                self.send(Request::Extend { secs: 900 })
            }
            gdk::Key::minus | gdk::Key::KP_Subtract => self.send(Request::Extend { secs: -900 }),
            gdk::Key::r => self.send(Request::Release),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    }

    /// The saver needs the screen: close the drawer first.
    pub(crate) fn start_now(self: &Rc<Self>) {
        self.hide();
        self.send(Request::Now);
    }

    fn show(self: &Rc<Self>, anchor: Option<Anchor>) {
        self.set_menu(false);
        self.open(anchor);
    }

    fn show_menu(self: &Rc<Self>, anchor: Option<Anchor>) {
        self.set_menu(true);
        self.open(anchor);
    }

    /// Switches between the drawer and the quick menu.
    fn set_menu(self: &Rc<Self>, on: bool) {
        if self.menu.replace(on) == on && self.visible.get() {
            return;
        }
        for w in &self.chrome {
            w.set_visible(!on);
        }
        let cfg = self.cfg.borrow();
        let width = if on { MENU_WIDTH } else { cfg.drawer.width };
        self.stage.set_geometry(width, cfg.drawer.max_height, cfg.drawer.gap);
        self.rendered.borrow_mut().clear();
    }

    fn open(self: &Rc<Self>, anchor: Option<Anchor>) {
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
            bar_anchor::drawers::opened("layover");
            crate::linux::tell_visible(true);
            self.spring.play_in(0);
        }
    }

    fn hide(self: &Rc<Self>) {
        if !self.visible.replace(false) {
            return;
        }
        crate::linux::tell_visible(false);
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
        if tab != self.tab.get() {
            self.sheet.replace(None);
        }
        self.tab.set(tab);
        self.render();
    }

    pub(crate) fn render(self: &Rc<Self>) {
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
        self.ensure_thumbs(&snap);
        // Each tab redraws only for what it shows: the gallery must not
        // jump each minute the idle count moves.
        let shown = match self.tab.get() {
            Tab::Hacks => serde_json::to_string(&(&snap.hacks, &snap.hack, snap.up_next.first()))
                .unwrap_or_default(),
            Tab::History => serde_json::to_string(&(&snap.history, &snap.day)).unwrap_or_default(),
            Tab::Now => serde_json::to_string(&snap).unwrap_or_default(),
        };
        if self.menu.get() {
            let key = format!("menu|{}", serde_json::to_string(&snap).unwrap_or_default());
            if *self.rendered.borrow() != key {
                *self.rendered.borrow_mut() = key;
                clear(&self.content);
                self.render_menu(&snap);
            }
            return;
        }
        let key = format!(
            "{:?}|{:?}|{:?}|{}|{}|{:?}|{}|{}|{}",
            self.tab.get(),
            self.sheet.borrow(),
            self.hacks_filter.borrow(),
            self.hacks_query.borrow(),
            self.hacks_rows.get(),
            self.wear.borrow().as_ref().map(|w| w.measured_at),
            self.measuring.get(),
            self.thumbs_gen.get(),
            shown,
        );
        if *self.rendered.borrow() == key {
            return;
        }
        *self.rendered.borrow_mut() = key;
        match self.tab.get() {
            Tab::Now => {
                clear(&self.content);
                self.render_now(&snap)
            }
            Tab::Hacks => self.render_hacks(&snap),
            Tab::History => {
                clear(&self.content);
                self.render_history(&snap)
            }
        }
    }

    fn render_now(self: &Rc<Self>, s: &Snapshot) {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 6);
        card.add_css_class("card");
        card.add_css_class(&s.state);
        card.append(&label("THE IDLE LINE", &["t-label"]));
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        head.append(&label(&s.headline, &["big", &s.state]));
        let aside = match (s.hold_mins, s.state.as_str()) {
            (Some(m), _) => format!("for {}", mins(m)),
            (None, "armed" | "loose") if s.idle_mins > 0 => format!("idle {}", mins(s.idle_mins)),
            _ => String::new(),
        };
        if !aside.is_empty() {
            let a = label(&aside, &["dim", "aside"]);
            a.set_valign(gtk::Align::Baseline);
            head.append(&a);
        }
        card.append(&head);
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
        let counting = matches!(s.state.as_str(), "armed" | "loose" | "saver");
        let rail = crate::rail::Rail::new(&s.rail, s.idle_mins, counting, s.state == "held");
        rail.set_margin_top(6);
        card.append(&rail);
        if s.stations.iter().any(|st| st.name == "Lock screen off" && st.on) {
            let still =
                s.stations.iter().find(|st| st.name == "Lock screen off").map(|st| st.at.clone());
            card.append(&label(
                &format!("A still lock screen goes dark after {}.", still.unwrap_or_default()),
                &["dim", "small"],
            ));
        }
        self.content.append(&card);

        self.content.append(&self.holds_card(s));
        if !s.up_next.is_empty() {
            self.content.append(&self.next_card(s));
        }

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

    /// The quick menu: where the line is, holds, and the few things done
    /// from the lamp.
    fn render_menu(self: &Rc<Self>, s: &Snapshot) {
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        head.append(&label(&s.headline, &["menu-state", &s.state]));
        let aside = match (s.hold_mins, s.rail.saver) {
            (Some(m), _) => format!("{} left", mins(m)),
            (None, Some(at)) if matches!(s.state.as_str(), "armed" | "loose") => {
                format!("saver in {}", mins(at.saturating_sub(s.idle_mins)))
            }
            _ => String::new(),
        };
        head.append(&label(&aside, &["dim", "small"]));
        self.content.append(&head);
        self.content.append(&label("Hold everything for", &["dim", "small"]));
        let chips = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        chips.set_homogeneous(true);
        chips.add_css_class("hold-chips");
        for (text, secs) in [("30m", 1800), ("1h", 3600), ("2h", 7200), ("4h", 14400)] {
            let b = gtk::Button::with_label(text);
            b.set_sensitive(s.state != "off");
            let w = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    d.send(Request::Hold { secs });
                    d.hide();
                }
            });
            chips.append(&b);
        }
        self.content.append(&chips);
        let items = gtk::Box::new(gtk::Orientation::Vertical, 2);
        items.add_css_class("menu-items");
        let item = |text: &str, key: &str, enabled: bool, f: MenuAction| {
            let b = gtk::Button::new();
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let t = label(text, &[]);
            t.set_hexpand(true);
            row.append(&t);
            row.append(&label(key, &["key-hint"]));
            b.set_child(Some(&row));
            b.set_sensitive(enabled);
            let w = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    f(&d);
                }
            });
            items.append(&b);
        };
        let can_start = !matches!(s.state.as_str(), "saver" | "dark" | "off") && !s.locked;
        item("Start saver now", "n", can_start, Box::new(|d| d.start_now()));
        item("Audition hacks\u{2026}", "a", s.state != "off", Box::new(|d| d.audition(None)));
        item("Open the drawer", "o", true, Box::new(|d| d.show(None)));
        item(
            if s.manual_hold { "Release your hold" } else { "Release (nothing held)" },
            "r",
            s.manual_hold,
            Box::new(|d| {
                d.send(Request::Release);
                d.hide();
            }),
        );
        self.content.append(&items);
    }

    fn holds_card(self: &Rc<Self>, s: &Snapshot) -> gtk::Box {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 8);
        card.add_css_class("card");
        card.append(&label("WHAT HOLDS THE LINE", &["t-label"]));
        if s.holding.is_empty() {
            card.append(&label("Nothing holds it.", &["dim", "small"]));
        }
        for h in &s.holding {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
            let dot = label("\u{25cf}", &["hold-dot", if h.mine { "mine" } else { "theirs" }]);
            dot.set_valign(gtk::Align::Start);
            row.append(&dot);
            let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
            text.set_hexpand(true);
            text.append(&wrapped(&h.what, &["hold-what"]));
            text.append(&wrapped(&h.effect, &["why"]));
            row.append(&text);
            if h.mine {
                let b = gtk::Button::with_label("Release");
                b.set_valign(gtk::Align::Center);
                let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 0);
                buttons.add_css_class("buttons");
                let w = Rc::downgrade(self);
                b.connect_clicked(move |_| {
                    if let Some(d) = w.upgrade() {
                        d.send(Request::Release);
                    }
                });
                buttons.append(&b);
                row.append(&buttons);
            }
            card.append(&row);
        }
        card.append(&label(
            if s.hold_mins.is_some() {
                "Hold everything for, from now"
            } else {
                "Hold everything for"
            },
            &["dim", "small"],
        ));
        let chips = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        chips.set_homogeneous(true);
        chips.add_css_class("hold-chips");
        for (text, secs) in [("30m", 1800), ("1h", 3600), ("2h", 7200), ("4h", 14400)] {
            let b = gtk::Button::with_label(text);
            b.set_focus_on_click(false);
            b.set_sensitive(s.state != "off");
            let w = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    d.send(Request::Hold { secs });
                }
            });
            chips.append(&b);
        }
        card.append(&chips);
        card
    }

    fn next_card(self: &Rc<Self>, s: &Snapshot) -> gtk::Box {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 8);
        card.add_css_class("card");
        card.append(&label("UP NEXT", &["t-label"]));
        let strip = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let width = self.cfg.borrow().drawer.width - 28.0 - 24.0;
        let aspect = self.thumbs.borrow().aspect();
        let small = (width - 18.0) / 5.0;
        for (i, id) in s.up_next.iter().take(4).enumerate() {
            let w = if i == 0 { small * 2.0 } else { small };
            let b = gtk::Box::new(gtk::Orientation::Vertical, 3);
            b.set_size_request(w as i32, -1);
            let pic = crate::thumbs::picture(&self.thumbs, id, (w * aspect).round() as i32, false);
            if i > 0 {
                pic.add_css_class("later");
            }
            b.append(&pic);
            let name =
                s.hacks.iter().find(|h| &h.id == id).map(|h| h.name.clone()).unwrap_or_default();
            let n = label(&name, &[if i == 0 { "next-name" } else { "kind" }]);
            n.set_ellipsize(gtk::pango::EllipsizeMode::End);
            n.set_max_width_chars(1);
            n.set_hexpand(true);
            b.append(&n);
            strip.append(&b);
        }
        card.append(&strip);
        card.append(&wrapped(
            "Each hands off after its turn (text sooner), then the screens go dark.",
            &["dim", "small"],
        ));
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        buttons.add_css_class("buttons");
        let start = gtk::Button::with_label("Start saver now");
        start.add_css_class("primary");
        start.set_hexpand(true);
        start.set_sensitive(!matches!(s.state.as_str(), "saver" | "dark" | "off") && !s.locked);
        let w = Rc::downgrade(self);
        start.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.start_now();
            }
        });
        buttons.append(&start);
        let skip = gtk::Button::with_label("Skip");
        skip.set_tooltip_text(Some("Start the next run with the hack after this one"));
        skip.set_sensitive(s.state != "off");
        let w = Rc::downgrade(self);
        skip.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.send(Request::Next { hack: None });
            }
        });
        buttons.append(&skip);
        card.append(&buttons);
        card
    }

    fn render_history(self: &Rc<Self>, s: &Snapshot) {
        let today = gtk::Box::new(gtk::Orientation::Vertical, 7);
        today.add_css_class("card");
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let t = label("TODAY", &["t-label"]);
        t.set_hexpand(true);
        head.append(&t);
        let d = &s.day;
        head.append(&label(
            &format!(
                "saver {} \u{b7} held {} \u{b7} dark {}",
                mins(d.saver_mins),
                mins(d.held_mins),
                mins(d.dark_mins)
            ),
            &["dim", "small"],
        ));
        today.append(&head);
        today.append(&crate::day::DayStrip::new(d));
        let hours = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        hours.set_homogeneous(true);
        for (i, h) in ["00", "06", "12", "18", "24"].iter().enumerate() {
            let l = label(h, &["hour"]);
            l.set_xalign(i as f32 / 4.0);
            hours.append(&l);
        }
        today.append(&hours);
        let legend = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        for (state, name) in
            [("armed", "armed"), ("saver", "saver"), ("held", "held"), ("dark", "dark")]
        {
            let item = gtk::Box::new(gtk::Orientation::Horizontal, 5);
            item.append(&label("\u{25a0}", &["swatch", &format!("day-{state}")]));
            item.append(&label(name, &["dim", "small"]));
            legend.append(&item);
        }
        today.append(&legend);
        self.content.append(&today);

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
        let card = gtk::Box::new(gtk::Orientation::Vertical, 10);
        card.add_css_class("card");
        let aspect = self.thumbs.borrow().aspect();
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
            if !e.hacks.is_empty() {
                let film = gtk::Box::new(gtk::Orientation::Horizontal, 3);
                film.set_margin_top(4);
                for id in e.hacks.iter().take(5) {
                    let pic = crate::thumbs::picture(
                        &self.thumbs,
                        id,
                        (48.0 * aspect).round() as i32,
                        false,
                    );
                    pic.set_size_request(48, (48.0 * aspect).round() as i32);
                    let name =
                        s.hacks.iter().find(|h| &h.id == id).map(|h| h.name.as_str()).unwrap_or(id);
                    pic.set_tooltip_text(Some(name));
                    film.append(&pic);
                }
                text.append(&film);
            }
            row.append(&text);
            card.append(&row);
        }
        self.content.append(&card);
    }

    /// Runs `layover wear` off the main thread; the cache it writes comes
    /// back through the file watch and `Msg::Measured`.
    pub(crate) fn measure(self: &Rc<Self>, ids: Vec<String>) {
        if self.measuring.replace(true) {
            return;
        }
        self.render();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = std::process::Command::new(layover_exe())
                .args(["wear", "--minutes", "60"])
                .args(&ids)
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
    pub(crate) fn preview(self: &Rc<Self>, id: &str) {
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

    /// Closes the drawer and steps through every hack on the screen, from
    /// `from` or the first.
    pub(crate) fn audition(self: &Rc<Self>, from: Option<String>) {
        self.hide();
        let tx = self.tx.clone();
        glib::timeout_add_local_once(Duration::from_millis(250), move || {
            let mut cmd = std::process::Command::new(layover_exe());
            cmd.arg("audition").stdin(std::process::Stdio::null());
            if let Some(id) = &from {
                cmd.args(["--from", id]);
            }
            match cmd.spawn() {
                Ok(mut child) => {
                    std::thread::spawn(move || {
                        let _ = child.wait();
                    });
                }
                Err(e) => {
                    let _ = tx
                        .send_blocking(Msg::Notice(format!("Couldn't start Audition: {e}"), true));
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
        self.shooting.set(true);
        let menu = tab.as_deref() == Some("menu");
        let tab = match tab.as_deref() {
            Some("hacks") => Tab::Hacks,
            Some("hacks-list") => {
                self.hacks_rows.set(true);
                Tab::Hacks
            }
            Some(t) if t.starts_with("sheet:") => {
                *self.sheet.borrow_mut() = Some(t["sheet:".len()..].to_string());
                Tab::Hacks
            }
            Some("history") => Tab::History,
            _ => Tab::Now,
        };
        self.tab.set(tab);
        // No layer surface here: give the window room for the panel.
        let width = self.cfg.borrow().drawer.width as i32 + 48;
        self.window.set_default_size(width, 980);
        if menu {
            self.show_menu(None);
        } else {
            self.show(None);
        }
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

/// Minutes as the lamp writes them: "9m", "1h", "1h15m".
pub(crate) fn mins(m: u64) -> String {
    match (m / 60, m % 60) {
        (0, m) => format!("{m}m"),
        (h, 0) => format!("{h}h"),
        (h, m) => format!("{h}h{m}m"),
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
