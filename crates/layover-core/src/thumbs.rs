//! The drawer's thumbnail cache, `$LAYOVER_CACHE_DIR/thumbs`: an index of
//! what each hack's pictures were drawn from, and three PNGs a hack (an
//! early frame, a settled frame and a loop strip). `layover thumbs` writes
//! it; the drawer reads it.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ThumbIndex {
    /// The canvas the hacks were drawn for, in logical pixels.
    pub canvas: [f32; 2],
    /// Each picture's size in pixels.
    pub size: [u32; 2],
    pub loop_frames: u32,
    pub loop_fps: u32,
    /// Hack id to the key of what it was drawn from.
    pub hacks: BTreeMap<String, String>,
}

/// Which picture of a hack.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shot {
    /// Half a minute in.
    Early,
    /// Two and a half minutes in, settled.
    Still,
    /// A few seconds of loop, frames stacked top to bottom.
    Loop,
}

impl ThumbIndex {
    pub fn path(dir: &Path) -> PathBuf {
        dir.join("index.json")
    }

    pub fn load(dir: &Path) -> Option<ThumbIndex> {
        serde_json::from_str(&std::fs::read_to_string(Self::path(dir)).ok()?).ok()
    }

    /// Write atomically: a drawer reading mid-write sees the old index.
    pub fn save(&self, dir: &Path) -> Result<()> {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        let path = Self::path(dir);
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(self)?)?;
        std::fs::rename(&tmp, &path).with_context(|| format!("writing {}", path.display()))
    }

    /// The file for one picture of `id`.
    pub fn file(dir: &Path, id: &str, shot: Shot) -> PathBuf {
        dir.join(match shot {
            Shot::Early => format!("{id}-early.png"),
            Shot::Still => format!("{id}.png"),
            Shot::Loop => format!("{id}-loop.png"),
        })
    }

    /// Whether `id` was drawn from `key` and its pictures are all there.
    pub fn fresh(&self, dir: &Path, id: &str, key: &str) -> bool {
        self.hacks.get(id).is_some_and(|k| k == key)
            && [Shot::Early, Shot::Still, Shot::Loop]
                .iter()
                .all(|s| Self::file(dir, id, *s).exists())
    }
}

/// The desktop's canvas from Hyprland's `j/monitors`: the bounding box of
/// every monitor in logical pixels. None when it can't be read.
pub fn canvas_from_hyprland(json: &str) -> Option<[f32; 2]> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let mut bounds: Option<[f32; 4]> = None;
    for m in v.as_array()? {
        let num = |k: &str| m.get(k).and_then(|x| x.as_f64());
        let scale = num("scale").filter(|s| *s > 0.0).unwrap_or(1.0);
        let (mut w, mut h) = (num("width")? / scale, num("height")? / scale);
        // Transforms 1, 3, 5 and 7 turn the output a quarter.
        if num("transform").is_some_and(|t| t as i64 % 2 == 1) {
            std::mem::swap(&mut w, &mut h);
        }
        let (x, y) = (num("x").unwrap_or(0.0), num("y").unwrap_or(0.0));
        let r = [x as f32, y as f32, (x + w) as f32, (y + h) as f32];
        bounds = Some(match bounds {
            None => r,
            Some(b) => [b[0].min(r[0]), b[1].min(r[1]), b[2].max(r[2]), b[3].max(r[3])],
        });
    }
    let b = bounds?;
    let (w, h) = (b[2] - b[0], b[3] - b[1]);
    (w > 0.0 && h > 0.0).then_some([w, h])
}

/// A thumbnail `width` wide in the canvas's shape, at least a 32:9 strip
/// tall.
pub fn size_for(canvas: [f32; 2], width: u32) -> [u32; 2] {
    let h = (width as f32 * canvas[1] / canvas[0].max(1.0)).round() as u32;
    [width, h.clamp(width * 9 / 32, width)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_canvas_is_every_monitor_together() {
        let g9 = r#"[{"x":0,"y":0,"width":2560,"height":1440,"scale":1.0,"transform":0},
                     {"x":2560,"y":0,"width":2560,"height":1440,"scale":1.0,"transform":0}]"#;
        assert_eq!(canvas_from_hyprland(g9), Some([5120.0, 1440.0]));
        let hidpi = r#"[{"x":0,"y":0,"width":3840,"height":2160,"scale":2.0,"transform":1}]"#;
        assert_eq!(canvas_from_hyprland(hidpi), Some([1080.0, 1920.0]));
        assert_eq!(canvas_from_hyprland("[]"), None);
        assert_eq!(canvas_from_hyprland("nope"), None);
    }

    #[test]
    fn sizes_keep_the_shape_within_reason() {
        assert_eq!(size_for([5120.0, 1440.0], 384), [384, 108]);
        assert_eq!(size_for([2560.0, 1440.0], 384), [384, 216]);
        assert_eq!(size_for([1080.0, 1920.0], 384), [384, 384]);
    }

    #[test]
    fn stale_or_missing_pictures_are_not_fresh() {
        let dir = std::env::temp_dir().join(format!("layover-thumbs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut idx = ThumbIndex::default();
        idx.hacks.insert("starfield".into(), "k1".into());
        assert!(!idx.fresh(&dir, "starfield", "k1"), "no files yet");
        for s in [Shot::Early, Shot::Still, Shot::Loop] {
            std::fs::write(ThumbIndex::file(&dir, "starfield", s), b"png").unwrap();
        }
        assert!(idx.fresh(&dir, "starfield", "k1"));
        assert!(!idx.fresh(&dir, "starfield", "k2"));
        idx.save(&dir).unwrap();
        assert_eq!(ThumbIndex::load(&dir).unwrap(), idx);
        let _ = std::fs::remove_dir_all(dir);
    }
}
