//! The drawer's side of the thumbnail cache: textures for each hack's
//! pictures, loaded once and kept until `layover thumbs` writes new ones,
//! and the loop that plays under the pointer.

use gtk::prelude::*;
use gtk::{gdk, glib};
use layover_core::paths;
use layover_core::thumbs::{Shot, ThumbIndex};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

#[derive(Default)]
pub struct Store {
    dir: PathBuf,
    index: Option<ThumbIndex>,
    shots: HashMap<(String, u8), Option<gdk::Texture>>,
    loops: HashMap<String, Option<Rc<Vec<gdk::Texture>>>>,
}

fn shot_code(s: Shot) -> u8 {
    match s {
        Shot::Early => 0,
        Shot::Still => 1,
        Shot::Loop => 2,
    }
}

impl Store {
    pub fn new() -> Store {
        let mut s = Store { dir: paths::thumbs_dir(), ..Default::default() };
        s.reload();
        s
    }

    /// Forget every texture and read the index again: `layover thumbs`
    /// wrote something.
    pub fn reload(&mut self) {
        self.index = ThumbIndex::load(&self.dir);
        self.shots.clear();
        self.loops.clear();
    }

    /// Height over width of the pictures (the desktop's shape).
    pub fn aspect(&self) -> f64 {
        self.index
            .as_ref()
            .filter(|i| i.size[0] > 0)
            .map(|i| i.size[1] as f64 / i.size[0] as f64)
            .unwrap_or(9.0 / 32.0)
    }

    pub fn fps(&self) -> u32 {
        self.index.as_ref().map(|i| i.loop_fps).filter(|f| *f > 0).unwrap_or(8)
    }

    /// Whether any of `ids` has no pictures yet.
    pub fn missing(&self, ids: &[&str]) -> bool {
        ids.iter().any(|id| self.index.as_ref().is_none_or(|i| !i.hacks.contains_key(*id)))
    }

    /// One picture of `id`, or None before `layover thumbs` drew it.
    pub fn shot(&mut self, id: &str, shot: Shot) -> Option<gdk::Texture> {
        let indexed = self.index.as_ref().is_some_and(|i| i.hacks.contains_key(id));
        let dir = self.dir.clone();
        self.shots
            .entry((id.to_string(), shot_code(shot)))
            .or_insert_with(|| {
                indexed
                    .then(|| gdk::Texture::from_filename(ThumbIndex::file(&dir, id, shot)).ok())
                    .flatten()
            })
            .clone()
    }

    /// The loop's frames, cut from its strip the first time they're asked
    /// for.
    pub fn frames(&mut self, id: &str) -> Option<Rc<Vec<gdk::Texture>>> {
        let index = self.index.clone()?;
        let dir = self.dir.clone();
        self.loops
            .entry(id.to_string())
            .or_insert_with(|| {
                if !index.hacks.contains_key(id) {
                    return None;
                }
                let strip =
                    gdk::Texture::from_filename(ThumbIndex::file(&dir, id, Shot::Loop)).ok()?;
                let (w, h) = (index.size[0] as usize, index.size[1] as usize);
                let n = index.loop_frames.max(1) as usize;
                if strip.width() as usize != w || strip.height() as usize != h * n {
                    return None;
                }
                let stride = w * 4;
                let mut bytes = vec![0u8; stride * h * n];
                strip.download(&mut bytes, stride);
                let frames = bytes
                    .chunks_exact(stride * h)
                    .map(|f| {
                        gdk::MemoryTexture::new(
                            w as i32,
                            h as i32,
                            gdk::MemoryFormat::B8g8r8a8Premultiplied,
                            &glib::Bytes::from(f),
                            stride,
                        )
                        .upcast::<gdk::Texture>()
                    })
                    .collect();
                Some(Rc::new(frames))
            })
            .clone()
    }
}

/// A picture that plays `id`'s loop while the pointer is over it, or all
/// the time with `always`, and shows its settled frame otherwise.
pub fn picture(store: &Rc<RefCell<Store>>, id: &str, height: i32, always: bool) -> gtk::Widget {
    let pic = gtk::Picture::new();
    pic.set_content_fit(gtk::ContentFit::Cover);
    pic.set_can_shrink(true);
    pic.set_size_request(-1, height);
    pic.add_css_class("thumb");
    let still = store.borrow_mut().shot(id, Shot::Still);
    match &still {
        Some(t) => pic.set_paintable(Some(t)),
        None => pic.add_css_class("empty"),
    }
    let timer: Rc<RefCell<Option<glib::SourceId>>> = Rc::default();
    let start = {
        let (store, pic, timer, id) = (store.clone(), pic.clone(), timer.clone(), id.to_string());
        move || {
            if timer.borrow().is_some() {
                return;
            }
            let Some(frames) = store.borrow_mut().frames(&id) else { return };
            let fps = store.borrow().fps();
            let at = Rc::new(std::cell::Cell::new(0usize));
            let p = pic.clone();
            let tick = move || {
                let i = at.get();
                p.set_paintable(Some(&frames[i % frames.len()]));
                at.set(i + 1);
                glib::ControlFlow::Continue
            };
            tick.clone()();
            let id = glib::timeout_add_local(Duration::from_millis(1000 / fps as u64), tick);
            *timer.borrow_mut() = Some(id);
        }
    };
    let stop = {
        let (pic, timer, still) = (pic.clone(), timer.clone(), still.clone());
        move || {
            if let Some(id) = timer.borrow_mut().take() {
                id.remove();
            }
            if let Some(t) = &still {
                pic.set_paintable(Some(t));
            }
        }
    };
    if always {
        start();
        let stop = stop.clone();
        pic.connect_unmap(move |_| stop());
    } else {
        let motion = gtk::EventControllerMotion::new();
        let s = start.clone();
        motion.connect_enter(move |_, _, _| s());
        let st = stop.clone();
        motion.connect_leave(move |_| st());
        pic.add_controller(motion);
        pic.connect_unmap(move |_| stop());
    }
    pic.upcast()
}
