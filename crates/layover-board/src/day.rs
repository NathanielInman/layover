//! The History tab's strip: today from midnight, each stretch in its
//! state's color, and a mark at now.

use gtk::glib;
use gtk::graphene::Rect;
use gtk::gsk::RoundedRect;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use layover_core::board::Day;
use std::cell::RefCell;

const HEIGHT: i32 = 22;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct DayStrip {
        pub day: RefCell<Day>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for DayStrip {
        const NAME: &'static str = "LoDayStrip";
        type Type = super::DayStrip;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for DayStrip {
        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for DayStrip {
        fn measure(&self, o: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            match o {
                gtk::Orientation::Horizontal => (120, 360, -1, -1),
                _ => (HEIGHT, HEIGHT, -1, -1),
            }
        }

        fn snapshot(&self, snap: &gtk::Snapshot) {
            let w = self.obj();
            let (width, height) = (w.width() as f32, w.height() as f32);
            let color = |state: &str| {
                let mut c = w.first_child();
                while let Some(child) = c {
                    if child.has_css_class(state) {
                        return child.color();
                    }
                    c = child.next_sibling();
                }
                w.color()
            };
            let whole = RoundedRect::from_rect(Rect::new(0.0, 0.0, width, height), 5.0);
            snap.push_rounded_clip(&whole);
            snap.append_color(&color("day-none"), &Rect::new(0.0, 0.0, width, height));
            let day = self.day.borrow();
            for s in &day.spans {
                let x = s.from * width;
                let span = ((s.to - s.from) * width).max(1.0);
                snap.append_color(
                    &color(&format!("day-{}", s.state)),
                    &Rect::new(x, 0.0, span, height),
                );
            }
            if day.now > 0.0 {
                let x = (day.now * width).min(width - 2.0);
                snap.append_color(&color("day-now"), &Rect::new(x, 0.0, 2.0, height));
            }
            snap.pop();
        }
    }
}

glib::wrapper! {
    pub struct DayStrip(ObjectSubclass<imp::DayStrip>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl DayStrip {
    pub fn new(day: &Day) -> DayStrip {
        let d: DayStrip = glib::Object::new();
        // Hidden children carry each state's color from the stylesheet.
        for class in ["day-none", "day-armed", "day-held", "day-saver", "day-dark", "day-now"] {
            let probe = gtk::Label::new(None);
            probe.add_css_class(class);
            probe.set_visible(false);
            probe.set_parent(&d);
        }
        *d.imp().day.borrow_mut() = day.clone();
        d.set_size_request(-1, HEIGHT);
        d
    }
}
