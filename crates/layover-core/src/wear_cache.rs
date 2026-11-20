//! The wear test's last results, `$LAYOVER_STATE_DIR/wear.json`. `layover
//! wear` writes it; the drawer's Hacks tab reads it.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WearCache {
    /// Unix seconds.
    pub measured_at: u64,
    /// Simulated minutes per hack.
    pub minutes: u32,
    pub hacks: Vec<WearRow>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WearRow {
    pub id: String,
    pub average: f32,
    pub max_dwell_secs: u32,
    pub hot_spot: f32,
    pub share: [f32; 3],
    pub peak: f32,
    /// Every budget it broke against the config of the run, as sentences.
    pub failures: Vec<String>,
}

impl WearCache {
    pub fn load(path: &Path) -> Option<WearCache> {
        serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
    }

    /// Write atomically: a drawer reading mid-write sees the old file.
    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(self)?)?;
        std::fs::rename(&tmp, path).with_context(|| format!("writing {}", path.display()))
    }

    pub fn row(&self, id: &str) -> Option<&WearRow> {
        self.hacks.iter().find(|r| r.id == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_a_file() {
        let dir = std::env::temp_dir().join(format!("layover-wear-{}", std::process::id()));
        let path = dir.join("wear.json");
        let c = WearCache {
            measured_at: 7,
            minutes: 60,
            hacks: vec![WearRow {
                id: "starfield".into(),
                max_dwell_secs: 2,
                ..Default::default()
            }],
        };
        c.save(&path).unwrap();
        assert_eq!(WearCache::load(&path).unwrap(), c);
        assert_eq!(WearCache::load(&path).unwrap().row("starfield").unwrap().max_dwell_secs, 2);
        let _ = std::fs::remove_dir_all(dir);
    }
}
