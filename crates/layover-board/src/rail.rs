//! The rail on the Now tab: the idle line drawn to scale, from the last
//! input to the dark, with a mark for how long the desk has been idle and
//! each station's time and how long until it comes.

use gtk::glib;
use gtk::graphene::{Point, Rect, Size};
use gtk::gsk::RoundedRect;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use layover_core::board::Rail as RailMins;
use std::cell::{Cell, RefCell};

const HEIGHT: i32 = 80;
const TRACK_Y: f32 = 26.0;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct Rail {
        pub rail: RefCell<RailMins>,
        pub idle: Cell<u64>,
        /// Whether the countdowns run: false while held or past the saver.
        pub counting: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Rail {
        const NAME: &'static str = "LoRail";
        type Type = super::Rail;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for Rail {
        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for Rail {
        fn measure(&self, o: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            match o {
                gtk::Orientation::Horizontal => (120, 360, -1, -1),
                _ => (HEIGHT, HEIGHT, -1, -1),
            }
        }

        fn snapshot(&self, snap: &gtk::Snapshot) {
            let w = self.obj();
            let width = w.width() as f32;
            let fg = w.color();
            let rgba =
                |a: f32| gtk::gdk::RGBA::new(fg.red(), fg.green(), fg.blue(), fg.alpha() * a);
            let accent = accent_of(&w);
            let rail = self.rail.borrow().clone();
            let idle = self.idle.get();
            let ends: Vec<u64> = [rail.saver, rail.lock, rail.dark].into_iter().flatten().collect();
            let scale = ends.iter().copied().max().unwrap_or(15).max(1) as f32;
            let pad = 9.0;
            let span = (width - 2.0 * pad).max(1.0);
            let x_of = |m: u64| pad + span * (m as f32 / scale).min(1.0);

            // The track, and the part already idle.
            let track = Rect::new(pad, TRACK_Y - 2.0, span, 4.0);
            snap.append_color(&rgba(0.14), &track);
            let done = x_of(idle) - pad;
            if done > 0.0 {
                let r = RoundedRect::from_rect(Rect::new(pad, TRACK_Y - 2.0, done, 4.0), 2.0);
                snap.push_rounded_clip(&r);
                snap.append_color(&accent, &Rect::new(pad, TRACK_Y - 2.0, done, 4.0));
                snap.pop();
            }

            // Stations: rings at their minute. Lock and dark at the same
            // minute share one.
            let mut stops: Vec<(u64, &str)> = Vec::new();
            if let Some(m) = rail.saver {
                stops.push((m, "SAVER"));
            }
            match (rail.lock, rail.dark) {
                (Some(l), Some(d)) if l == d => stops.push((d, "LOCK + SCREENS OFF")),
                (l, d) => {
                    if let Some(l) = l {
                        stops.push((l, "LOCK"));
                    }
                    if let Some(d) = d {
                        stops.push((d, "SCREENS OFF"));
                    }
                }
            }
            stops.sort();
            let ring = rgba(0.55);
            dot(snap, pad, &ring, 5.0);
            for (m, _) in &stops {
                let reached = idle >= *m && self.counting.get();
                dot(snap, x_of(*m), if reached { &accent } else { &ring }, 7.0);
            }

            // The idle mark and its label above the track.
            if idle > 0 {
                let x = x_of(idle);
                snap.append_color(&accent, &Rect::new(x - 1.0, TRACK_Y - 12.0, 2.0, 18.0));
                text(
                    snap,
                    &w,
                    &format!("idle {}", mins(idle)),
                    x,
                    0.0,
                    Align::Center,
                    width,
                    &accent,
                    true,
                );
            }

            // Labels under each stop: name, time, and how long until.
            let below = TRACK_Y + 14.0;
            text(snap, &w, "0m", pad - 4.0, below + 13.0, Align::Start, width, &rgba(0.6), false);
            let n = stops.len();
            for (i, (m, name)) in stops.iter().enumerate() {
                let x = x_of(*m);
                let align = if i + 1 == n { Align::End } else { Align::Center };
                let x = if i + 1 == n { width - pad + 4.0 } else { x };
                text(snap, &w, name, x, below, align, width, &rgba(0.6), false);
                text(snap, &w, &mins(*m), x, below + 13.0, align, width, &fg, false);
                let until = if self.counting.get() && idle < *m {
                    format!("in {}", mins(*m - idle))
                } else if idle >= *m && self.counting.get() {
                    "now".into()
                } else {
                    "held".into()
                };
                text(snap, &w, &until, x, below + 26.0, align, width, &rgba(0.6), false);
            }
        }
    }
}

glib::wrapper! {
    pub struct Rail(ObjectSubclass<imp::Rail>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

#[derive(Clone, Copy)]
enum Align {
    Start,
    Center,
    End,
}

fn mins(m: u64) -> String {
    match (m / 60, m % 60) {
        (0, m) => format!("{m}m"),
        (h, 0) => format!("{h}h"),
        (h, m) => format!("{h}h{m}m"),
    }
}

/// The accent: the color a child labelled `.rail-accent` would get.
fn accent_of(w: &Rail) -> gtk::gdk::RGBA {
    w.first_child().map(|c| c.color()).unwrap_or_else(|| w.color())
}

fn dot(snap: &gtk::Snapshot, x: f32, color: &gtk::gdk::RGBA, r: f32) {
    let rect = Rect::new(x - r, TRACK_Y - r, 2.0 * r, 2.0 * r);
    snap.push_rounded_clip(&RoundedRect::from_rect(rect, r));
    snap.append_color(color, &rect);
    snap.pop();
    let inner = r - 2.5;
    if inner > 0.0 {
        let ir = Rect::new(x - inner, TRACK_Y - inner, 2.0 * inner, 2.0 * inner);
        snap.push_rounded_clip(&RoundedRect::new(
            ir,
            Size::new(inner, inner),
            Size::new(inner, inner),
            Size::new(inner, inner),
            Size::new(inner, inner),
        ));
        snap.append_color(&gtk::gdk::RGBA::new(0.12, 0.13, 0.14, 1.0), &ir);
        snap.pop();
    }
}

#[allow(clippy::too_many_arguments)]
fn text(
    snap: &gtk::Snapshot,
    w: &Rail,
    s: &str,
    x: f32,
    y: f32,
    align: Align,
    width: f32,
    color: &gtk::gdk::RGBA,
    bold: bool,
) {
    let layout = w.create_pango_layout(Some(s));
    let mut font = w.pango_context().font_description().unwrap_or_default();
    font.set_size((font.size() as f64 * if bold { 0.8 } else { 0.72 }) as i32);
    if bold {
        font.set_weight(gtk::pango::Weight::Bold);
    }
    layout.set_font_description(Some(&font));
    let (tw, _) = layout.pixel_size();
    let tw = tw as f32;
    let left = match align {
        Align::Start => x,
        Align::Center => x - tw / 2.0,
        Align::End => x - tw,
    }
    .clamp(0.0, (width - tw).max(0.0));
    snap.save();
    snap.translate(&Point::new(left, y));
    snap.append_layout(&layout, color);
    snap.restore();
}

impl Rail {
    pub fn new(rail: &RailMins, idle: u64, counting: bool, held: bool) -> Rail {
        let r: Rail = glib::Object::new();
        r.add_css_class("rail");
        // An empty child carries the accent color from CSS.
        let probe = gtk::Label::new(None);
        probe.add_css_class("rail-accent");
        if held {
            probe.add_css_class("held");
        }
        probe.set_visible(false);
        probe.set_parent(&r);
        *r.imp().rail.borrow_mut() = rail.clone();
        r.imp().idle.set(idle);
        r.imp().counting.set(counting);
        r.set_size_request(-1, HEIGHT);
        r
    }
}
