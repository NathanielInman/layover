//! The Hacks tab: a gallery of every hack with its picture, a switch to
//! take it out of the rotation and a star to bring it up twice a round, and
//! a sheet per hack with its loop, how it changes, how often it comes up and
//! its wear numbers against the budget.

use crate::drawer::{Drawer, clear, label, wrapped};
use crate::thumbs;
use gtk::glib;
use gtk::prelude::*;
use layover_core::board::{HackView, Snapshot};
use layover_core::config::Weight;
use layover_core::paths;
use layover_core::protocol::Request;
use layover_core::thumbs::Shot;
use std::rc::Rc;

/// The gallery's widgets that outlive a render: typing in the search box
/// must not lose focus when the list under it is rebuilt.
pub struct HacksUi {
    pub root: gtk::Box,
    pub search: gtk::SearchEntry,
    chips: gtk::FlowBox,
    count: gtk::Label,
    strips: gtk::Button,
    rows: gtk::Button,
    list: gtk::Box,
}

/// Which hacks the gallery shows.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Filter {
    All,
    On,
    Off,
    Starred,
    Kind(String),
}

impl Filter {
    fn keeps(&self, h: &HackView) -> bool {
        match self {
            Filter::All => true,
            Filter::On => h.weight != Weight::Never,
            Filter::Off => h.weight == Weight::Never,
            Filter::Starred => h.weight == Weight::Often,
            Filter::Kind(k) => &h.kind == k,
        }
    }
}

/// The families in the order the chips show them.
const KINDS: [&str; 6] = ["Fields", "3D", "Growth", "Particles", "Lines", "Text"];

fn kind_label(h: &HackView) -> String {
    match h.kind.as_str() {
        "3D" => "3D".into(),
        "Text" => "Text".into(),
        k => k.trim_end_matches('s').to_string(),
    }
}

impl Drawer {
    /// Width of a card's picture: the panel less its padding and the
    /// card's.
    fn picture_width(&self) -> f64 {
        (self.cfg.borrow().drawer.width - 28.0 - 14.0).max(160.0)
    }

    fn picture_height(&self, width: f64) -> i32 {
        (width * self.thumbs.borrow().aspect()).round() as i32
    }

    pub(crate) fn render_hacks(self: &Rc<Self>, s: &Snapshot) {
        let open = self.sheet.borrow().clone();
        if let Some(id) = open
            && let Some(i) = s.hacks.iter().position(|h| h.id == id)
        {
            clear(&self.content);
            self.render_sheet(s, i);
            return;
        }
        self.sheet.replace(None);
        let ui = self.hacks_ui();
        if self.content.first_child().as_ref() != Some(ui.root.upcast_ref()) {
            clear(&self.content);
            self.content.append(&ui.root);
        }
        self.fill_gallery(&ui, s);
    }

    /// Draws thumbnails that are missing or stale, once per drawer start,
    /// in the background and at low priority.
    pub(crate) fn ensure_thumbs(self: &Rc<Self>, s: &Snapshot) {
        if self.thumbs_started.get() || self.shooting.get() || s.hacks.is_empty() {
            return;
        }
        self.thumbs_started.set(true);
        let tx = self.tx.clone();
        let first = {
            let ids: Vec<&str> = s.hacks.iter().map(|h| h.id.as_str()).collect();
            self.thumbs.borrow().missing(&ids)
        };
        std::thread::spawn(move || {
            use std::os::unix::process::CommandExt;
            let mut cmd = std::process::Command::new(crate::drawer::layover_exe());
            cmd.arg("thumbs")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped());
            // SAFETY: setpriority only; the drawer stays responsive.
            unsafe {
                cmd.pre_exec(|| {
                    libc::setpriority(libc::PRIO_PROCESS, 0, 15);
                    Ok(())
                });
            }
            let msg = match cmd.output() {
                Ok(o) if o.status.success() => None,
                Ok(o) => Some(format!(
                    "Couldn't draw the thumbnails: {}",
                    String::from_utf8_lossy(&o.stderr).lines().last().unwrap_or("it failed")
                )),
                Err(e) => Some(format!("Couldn't run layover thumbs: {e}")),
            };
            let _ = tx.send_blocking(crate::drawer::Msg::ThumbsDone(msg));
        });
        if first {
            self.flash(
                "Drawing a picture of each hack, about a minute the first time.".into(),
                false,
            );
        }
    }

    fn hacks_ui(self: &Rc<Self>) -> Rc<HacksUi> {
        if let Some(ui) = self.hacks_ui.borrow().as_ref() {
            return ui.clone();
        }
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);

        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let search = gtk::SearchEntry::new();
        search.set_placeholder_text(Some("Find a hack"));
        search.set_hexpand(true);
        let w = Rc::downgrade(self);
        search.connect_search_changed(move |e| {
            if let Some(d) = w.upgrade() {
                *d.hacks_query.borrow_mut() = e.text().to_string();
                d.render();
            }
        });
        let w = Rc::downgrade(self);
        search.connect_stop_search(move |e| {
            e.set_text("");
            if let Some(d) = w.upgrade() {
                GtkWindowExt::set_focus(&d.window, None::<&gtk::Widget>);
            }
        });
        bar.append(&search);
        let seg = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        seg.add_css_class("seg");
        let strips = gtk::Button::with_label("Strips");
        let rows = gtk::Button::with_label("List");
        for (b, list) in [(&strips, false), (&rows, true)] {
            b.set_focus_on_click(false);
            let w = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    d.hacks_rows.set(list);
                    d.render();
                }
            });
            seg.append(b);
        }
        bar.append(&seg);
        root.append(&bar);

        let chips = gtk::FlowBox::new();
        chips.set_selection_mode(gtk::SelectionMode::None);
        chips.set_max_children_per_line(12);
        chips.set_row_spacing(5);
        chips.set_column_spacing(5);
        chips.set_homogeneous(false);
        chips.add_css_class("chips");
        root.append(&chips);

        let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let count = label("", &["dim", "count"]);
        count.set_hexpand(true);
        count.set_ellipsize(gtk::pango::EllipsizeMode::End);
        line.append(&count);
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        buttons.add_css_class("buttons");
        let measure = gtk::Button::with_label("Measure");
        measure.set_tooltip_text(Some("Run the wear test on every hack against your config"));
        let w = Rc::downgrade(self);
        measure.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.measure(Vec::new());
            }
        });
        buttons.append(&measure);
        let audition = gtk::Button::with_label("Audition");
        audition.add_css_class("primary");
        audition.set_tooltip_text(Some(
            "Step through every hack on the screen and keep, leave out or star each (a)",
        ));
        let w = Rc::downgrade(self);
        audition.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.audition(None);
            }
        });
        buttons.append(&audition);
        line.append(&buttons);
        root.append(&line);

        let list = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.append(&list);

        let ui = Rc::new(HacksUi { root, search, chips, count, strips, rows, list });
        *self.hacks_ui.borrow_mut() = Some(ui.clone());
        ui
    }

    fn fill_gallery(self: &Rc<Self>, ui: &HacksUi, s: &Snapshot) {
        let rows = self.hacks_rows.get();
        for (b, on) in [(&ui.strips, !rows), (&ui.rows, rows)] {
            if on {
                b.add_css_class("on");
            } else {
                b.remove_css_class("on");
            }
        }

        let filter = self.hacks_filter.borrow().clone();
        let on = s.hacks.iter().filter(|h| h.weight != Weight::Never).count();
        let starred = s.hacks.iter().filter(|h| h.weight == Weight::Often).count();
        let mut defs = vec![
            (Filter::All, format!("All {}", s.hacks.len())),
            (Filter::On, format!("In rotation {on}")),
            (Filter::Off, format!("Off {}", s.hacks.len() - on)),
            (Filter::Starred, format!("Starred {starred}")),
        ];
        for k in KINDS {
            if s.hacks.iter().any(|h| h.kind == k) {
                defs.push((Filter::Kind(k.into()), k.into()));
            }
        }
        while let Some(c) = ui.chips.first_child() {
            ui.chips.remove(&c);
        }
        for (f, text) in defs {
            let b = gtk::Button::with_label(&text);
            b.add_css_class("chip");
            b.set_focus_on_click(false);
            if f == filter {
                b.add_css_class("on");
            }
            let w = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    *d.hacks_filter.borrow_mut() = f.clone();
                    d.render();
                }
            });
            ui.chips.insert(&b, -1);
        }
        let mut count = format!("{on} of {} in rotation", s.hacks.len());
        if starred > 0 {
            count.push_str(&format!(" \u{b7} {starred} starred"));
        }
        ui.count.set_label(&count);

        clear(&ui.list);
        let query = self.hacks_query.borrow().trim().to_lowercase();
        let shown: Vec<&HackView> = s
            .hacks
            .iter()
            .filter(|h| filter.keeps(h))
            .filter(|h| query.is_empty() || h.name.to_lowercase().contains(&query))
            .collect();
        if shown.is_empty() {
            ui.list.append(&label("No hack matches.", &["dim", "empty-note"]));
        }
        for h in shown {
            let card = if rows { self.hack_row(s, h) } else { self.hack_card(s, h) };
            ui.list.append(&card);
        }
    }

    fn wear_mark(&self, id: &str) -> Option<gtk::Label> {
        let wear = self.wear.borrow();
        let row = wear.as_ref()?.row(id)?;
        Some(if row.failures.is_empty() {
            label("passes", &["pass"])
        } else {
            label("fails", &["fail"])
        })
    }

    /// The star and the switch for `h`.
    fn controls(self: &Rc<Self>, h: &HackView) -> (gtk::ToggleButton, gtk::Switch) {
        let star = gtk::ToggleButton::new();
        star.set_icon_name(if h.weight == Weight::Often {
            "starred-symbolic"
        } else {
            "non-starred-symbolic"
        });
        star.add_css_class("star");
        star.set_active(h.weight == Weight::Often);
        star.set_valign(gtk::Align::Center);
        star.set_focus_on_click(false);
        star.set_tooltip_text(Some(if h.weight == Weight::Often {
            "Starred: comes up twice a round"
        } else {
            "Star: twice a round"
        }));
        let switch = gtk::Switch::new();
        switch.set_active(h.weight != Weight::Never);
        switch.set_valign(gtk::Align::Center);
        switch.set_tooltip_text(Some("In the rotation"));
        let (w, id) = (Rc::downgrade(self), h.id.clone());
        let was = h.weight;
        star.connect_toggled(move |b| {
            let weight = if b.is_active() { Weight::Often } else { Weight::Sometimes };
            if let Some(d) = w.upgrade()
                && weight != was
            {
                d.set_weight(&id, weight);
            }
        });
        let (w, id) = (Rc::downgrade(self), h.id.clone());
        switch.connect_state_set(move |_, on| {
            let weight = if on { Weight::Sometimes } else { Weight::Never };
            if let Some(d) = w.upgrade()
                && (weight == Weight::Never) != (was == Weight::Never)
            {
                d.set_weight(&id, weight);
            }
            glib::Propagation::Proceed
        });
        (star, switch)
    }

    pub(crate) fn set_weight(self: &Rc<Self>, id: &str, weight: Weight) {
        self.send(Request::Rotation { hack: id.into(), weight });
    }

    fn open_sheet(self: &Rc<Self>, id: &str) {
        *self.sheet.borrow_mut() = Some(id.to_string());
        self.render();
    }

    fn opener(self: &Rc<Self>, w: &impl IsA<gtk::Widget>, id: &str) {
        let click = gtk::GestureClick::new();
        let (d, id) = (Rc::downgrade(self), id.to_string());
        click.connect_released(move |_, _, _, _| {
            if let Some(d) = d.upgrade() {
                d.open_sheet(&id);
            }
        });
        w.add_controller(click);
        w.set_cursor_from_name(Some("pointer"));
    }

    fn hack_card(self: &Rc<Self>, s: &Snapshot, h: &HackView) -> gtk::Widget {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 6);
        card.add_css_class("card");
        card.add_css_class("hack");
        if h.weight == Weight::Never {
            card.add_css_class("out");
        }
        let width = self.picture_width();
        let overlay = gtk::Overlay::new();
        let pic = thumbs::picture(&self.thumbs, &h.id, self.picture_height(width), false);
        overlay.set_child(Some(&pic));
        let badge = if s.hack.as_deref() == Some(h.name.as_str()) {
            Some("ON SCREEN")
        } else if s.up_next.first() == Some(&h.id) {
            Some("UP NEXT")
        } else {
            None
        };
        if let Some(text) = badge {
            let badge = label(text, &["badge"]);
            badge.set_halign(gtk::Align::Start);
            badge.set_valign(gtk::Align::Start);
            overlay.add_overlay(&badge);
        }
        self.opener(&overlay, &h.id);
        card.append(&overlay);

        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.add_css_class("hack-row");
        let text = gtk::Box::new(gtk::Orientation::Vertical, 0);
        text.set_hexpand(true);
        let name = label(&h.name, &["hack-name"]);
        self.opener(&name, &h.id);
        text.append(&name);
        let sub = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        sub.append(&label(&kind_label(h), &["kind"]));
        if let Some(m) = self.wear_mark(&h.id) {
            sub.append(&m);
        }
        text.append(&sub);
        row.append(&text);
        let (star, switch) = self.controls(h);
        row.append(&star);
        row.append(&switch);
        card.append(&row);
        card.upcast()
    }

    fn hack_row(self: &Rc<Self>, s: &Snapshot, h: &HackView) -> gtk::Widget {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        row.add_css_class("hack-line");
        if h.weight == Weight::Never {
            row.add_css_class("out");
        }
        let pic = thumbs::picture(&self.thumbs, &h.id, self.picture_height(120.0), false);
        pic.set_size_request(120, self.picture_height(120.0));
        pic.set_hexpand(false);
        self.opener(&pic, &h.id);
        row.append(&pic);
        let text = gtk::Box::new(gtk::Orientation::Vertical, 0);
        text.set_hexpand(true);
        text.set_valign(gtk::Align::Center);
        let name = label(&h.name, &["hack-name"]);
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        self.opener(&name, &h.id);
        text.append(&name);
        let mut sub = kind_label(h);
        if s.hack.as_deref() == Some(h.name.as_str()) {
            sub.push_str(" \u{b7} on screen");
        }
        text.append(&label(&sub, &["kind"]));
        row.append(&text);
        let (star, switch) = self.controls(h);
        row.append(&star);
        row.append(&switch);
        row.upcast()
    }

    fn render_sheet(self: &Rc<Self>, s: &Snapshot, i: usize) {
        let h = &s.hacks[i];
        let n = s.hacks.len();

        let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        top.add_css_class("buttons");
        let back = gtk::Button::with_label("\u{2039} All hacks");
        let w = Rc::downgrade(self);
        back.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.close_sheet();
            }
        });
        top.append(&back);
        let at = label(&format!("{} of {n}", i + 1), &["dim", "count"]);
        at.set_hexpand(true);
        at.set_xalign(1.0);
        top.append(&at);
        for (text, step, tip) in
            [("\u{2039}", n - 1, "Previous hack"), ("\u{203a}", 1, "Next hack")]
        {
            let b = gtk::Button::with_label(text);
            b.set_tooltip_text(Some(tip));
            let (w, to) = (Rc::downgrade(self), s.hacks[(i + step) % n].id.clone());
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade() {
                    d.open_sheet(&to);
                }
            });
            top.append(&b);
        }
        self.content.append(&top);

        let width = self.picture_width() + 12.0;
        let pic = thumbs::picture(&self.thumbs, &h.id, self.picture_height(width), true);
        pic.add_css_class("big-thumb");
        self.content.append(&pic);

        let head = gtk::Box::new(gtk::Orientation::Vertical, 3);
        let title = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        title.append(&label(&h.name, &["sheet-name"]));
        let kind = label(&kind_label(h), &["kind"]);
        kind.set_valign(gtk::Align::Baseline);
        title.append(&kind);
        if s.hack.as_deref() == Some(h.name.as_str()) {
            title.append(&label("ON SCREEN", &["showing"]));
        }
        head.append(&title);
        head.append(&wrapped(&h.about, &["reason"]));
        if !h.credit.is_empty() {
            head.append(&wrapped(&h.credit, &["about"]));
        }
        self.content.append(&head);

        let stills = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        stills.set_homogeneous(true);
        let half = (width - 8.0) / 2.0;
        for (shot, caption) in [(Shot::Early, "at 0:30"), (Shot::Still, "at 2:30")] {
            let b = gtk::Box::new(gtk::Orientation::Vertical, 3);
            let p = gtk::Picture::new();
            p.set_content_fit(gtk::ContentFit::Cover);
            p.set_can_shrink(true);
            p.set_size_request(-1, self.picture_height(half));
            p.add_css_class("thumb");
            match self.thumbs.borrow_mut().shot(&h.id, shot) {
                Some(t) => p.set_paintable(Some(&t)),
                None => p.add_css_class("empty"),
            }
            b.append(&p);
            b.append(&label(caption, &["kind"]));
            stills.append(&b);
        }
        self.content.append(&stills);

        self.content.append(&self.weight_card(s, h));
        self.content.append(&self.wear_card(h));
    }

    fn close_sheet(self: &Rc<Self>) {
        self.sheet.replace(None);
        self.render();
    }

    /// Escape and the arrows on a sheet. True when the key was used.
    pub(crate) fn sheet_key(self: &Rc<Self>, key: gtk::gdk::Key) -> bool {
        let Some(id) = self.sheet.borrow().clone() else { return false };
        let snap = self.snap.borrow().clone().unwrap_or_default();
        let n = snap.hacks.len().max(1);
        let i = snap.hacks.iter().position(|h| h.id == id).unwrap_or(0);
        match key {
            gtk::gdk::Key::Escape | gtk::gdk::Key::BackSpace => self.close_sheet(),
            gtk::gdk::Key::Left => {
                if let Some(h) = snap.hacks.get((i + n - 1) % n) {
                    self.open_sheet(&h.id.clone());
                }
            }
            gtk::gdk::Key::Right => {
                if let Some(h) = snap.hacks.get((i + 1) % n) {
                    self.open_sheet(&h.id.clone());
                }
            }
            gtk::gdk::Key::p => self.preview(&id),
            gtk::gdk::Key::a => self.audition(Some(id)),
            _ => return false,
        }
        true
    }

    fn weight_card(self: &Rc<Self>, s: &Snapshot, h: &HackView) -> gtk::Box {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 8);
        card.add_css_class("card");
        card.append(&label("IN THE ROTATION", &["t-label"]));
        let seg = gtk::Box::new(gtk::Orientation::Horizontal, 3);
        seg.add_css_class("seg");
        seg.add_css_class("wide");
        seg.set_homogeneous(true);
        for (weight, text) in
            [(Weight::Never, "Never"), (Weight::Sometimes, "Sometimes"), (Weight::Often, "Often")]
        {
            let b = gtk::Button::with_label(text);
            b.set_focus_on_click(false);
            if weight == h.weight {
                b.add_css_class("on");
                b.add_css_class(weight.as_str());
            }
            let (w, id) = (Rc::downgrade(self), h.id.clone());
            let was = h.weight;
            b.connect_clicked(move |_| {
                if let Some(d) = w.upgrade()
                    && weight != was
                {
                    d.set_weight(&id, weight);
                }
            });
            seg.append(&b);
        }
        card.append(&seg);
        card.append(&wrapped(&odds(s, h), &["reason"]));

        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        buttons.add_css_class("buttons");
        let audition = gtk::Button::with_label("Audition from here");
        audition.add_css_class("primary");
        audition.set_tooltip_text(Some("Step through every hack on the screen from this one (a)"));
        let (w, id) = (Rc::downgrade(self), h.id.clone());
        audition.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.audition(Some(id.clone()));
            }
        });
        card.append(&audition);
        let preview = gtk::Button::with_label("Preview 20s");
        preview.set_tooltip_text(Some("Close the drawer and show this hack for 20 seconds (p)"));
        let (w, id) = (Rc::downgrade(self), h.id.clone());
        preview.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.preview(&id);
            }
        });
        buttons.append(&preview);
        let next = s.up_next.first() == Some(&h.id);
        let pin = gtk::Button::with_label(if next { "Plays next" } else { "Play it next time" });
        pin.set_sensitive(!next);
        pin.set_tooltip_text(Some("Start the next run of the saver with this hack"));
        let (w, id) = (Rc::downgrade(self), h.id.clone());
        pin.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.send(Request::Next { hack: Some(id.clone()) });
            }
        });
        buttons.append(&pin);
        card.append(&buttons);
        card
    }

    fn wear_card(self: &Rc<Self>, h: &HackView) -> gtk::Box {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 7);
        card.add_css_class("card");
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let t = label("RULE ONE", &["t-label"]);
        t.set_hexpand(true);
        head.append(&t);
        let wear = self.wear.borrow().clone();
        let row = wear.as_ref().and_then(|w| w.row(&h.id)).cloned();
        if let Some(r) = &row {
            head.append(&if r.failures.is_empty() {
                label("passes", &["pass"])
            } else {
                label("fails", &["fail"])
            });
        }
        card.append(&head);
        let care = self.cfg.borrow().care.clone();
        match &row {
            Some(r) => {
                let when = wear
                    .as_ref()
                    .map(|w| crate::drawer::local_time(w.measured_at))
                    .unwrap_or_default();
                card.append(&label(
                    &format!(
                        "{} on a 256\u{d7}72 canvas \u{b7} measured {when}",
                        span(wear.as_ref().map(|w| w.minutes).unwrap_or(60))
                    ),
                    &["dim", "small"],
                ));
                let dwell_budget = care.max_dwell.0.as_secs_f32();
                for (name, v, budget, text) in [
                    (
                        "Average",
                        r.average,
                        care.max_average,
                        format!("{} / {}", pct(r.average), pct(care.max_average)),
                    ),
                    (
                        "Longest dwell",
                        r.max_dwell_secs as f32,
                        dwell_budget,
                        format!("{}s / {}s", r.max_dwell_secs, dwell_budget as u32),
                    ),
                    (
                        "Hottest area",
                        r.hot_spot,
                        care.max_hot_spot,
                        format!("{} / {}", pct(r.hot_spot), pct(care.max_hot_spot)),
                    ),
                    (
                        "Peak drive",
                        r.peak,
                        care.max_drive,
                        format!("{} / {}", pct(r.peak), pct(care.max_drive)),
                    ),
                ] {
                    card.append(&meter(name, v / budget.max(1e-6), &text));
                }
                card.append(&meter(
                    "R \u{b7} G \u{b7} B",
                    r.share.iter().cloned().fold(0.0, f32::max) / 0.4,
                    &format!(
                        "{:.0}\u{b7}{:.0}\u{b7}{:.0}",
                        r.share[0] * 100.0,
                        r.share[1] * 100.0,
                        r.share[2] * 100.0
                    ),
                ));
                for f in &r.failures {
                    card.append(&wrapped(f, &["why"]));
                }
                let heat = paths::heat_map(&h.id);
                if let Ok(t) = gtk::gdk::Texture::from_filename(&heat) {
                    let p = gtk::Picture::for_paintable(&t);
                    p.set_content_fit(gtk::ContentFit::Fill);
                    p.set_can_shrink(true);
                    let width = self.picture_width();
                    p.set_size_request(-1, (width * 72.0 / 256.0).round() as i32);
                    p.add_css_class("thumb");
                    card.append(&p);
                    card.append(&label(
                        "Where the light lands over the run. Even is good.",
                        &["dim", "small"],
                    ));
                }
            }
            None => card.append(&wrapped(
                "Not measured yet. The build tests every hack against the shipped budget; Measure tests it against yours.",
                &["dim", "small"],
            )),
        }
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        buttons.add_css_class("buttons");
        let measure = gtk::Button::with_label(if self.measuring.get() {
            "Measuring\u{2026}"
        } else {
            "Measure this hack"
        });
        measure.set_sensitive(!self.measuring.get());
        let (w, id) = (Rc::downgrade(self), h.id.clone());
        measure.connect_clicked(move |_| {
            if let Some(d) = w.upgrade() {
                d.measure(vec![id.clone()]);
            }
        });
        buttons.append(&measure);
        card.append(&buttons);
        card
    }
}

/// How often `h` comes up, in a sentence.
fn odds(s: &Snapshot, h: &HackView) -> String {
    let on = s.hacks.iter().filter(|x| x.weight != Weight::Never).count();
    let starred = s.hacks.iter().filter(|x| x.weight == Weight::Often).count();
    let turns = if on >= 3 { on + starred } else { on };
    match h.weight {
        Weight::Never => "Out of the rotation. Preview and Audition still show it.".into(),
        Weight::Sometimes => format!("Once a round of {turns} turns."),
        Weight::Often if on < 3 => {
            "Starred, but with fewer than three hacks in the rotation a star changes nothing."
                .into()
        }
        Weight::Often => format!("Twice a round of {turns} turns, half a round apart."),
    }
}

fn pct(v: f32) -> String {
    format!("{:.1}%", v * 100.0)
}

fn span(minutes: u32) -> String {
    if minutes.is_multiple_of(60) { format!("{}h", minutes / 60) } else { format!("{minutes}m") }
}

/// A row: name, a bar of how much of its budget a value uses, the numbers.
fn meter(name: &str, used: f32, text: &str) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.add_css_class("meter");
    let n = label(name, &["meter-name"]);
    n.set_width_chars(13);
    row.append(&n);
    let bar = gtk::LevelBar::for_interval(0.0, 1.0);
    bar.set_value(used.clamp(0.0, 1.0) as f64);
    bar.set_hexpand(true);
    bar.set_valign(gtk::Align::Center);
    bar.remove_offset_value(Some(gtk::LEVEL_BAR_OFFSET_LOW));
    bar.remove_offset_value(Some(gtk::LEVEL_BAR_OFFSET_HIGH));
    bar.remove_offset_value(Some(gtk::LEVEL_BAR_OFFSET_FULL));
    if used > 1.0 {
        bar.add_css_class("over");
    }
    row.append(&bar);
    let v = label(text, &["meter-value"]);
    v.set_xalign(1.0);
    v.set_width_chars(13);
    row.append(&v);
    row
}
