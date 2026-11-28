//! Changes to `layover.toml` that keep its comments and layout. The drawer's
//! rotation switch and star, Audition and `layover rotation` all come here,
//! through the daemon when it runs.

use crate::config::{Config, Weight};
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use toml_edit::{Array, DocumentMut, Item, Table, Value};

/// `text` with hack `id` set to `weight` in `[saver]`: out of the rotation
/// in `skip`, starred in `often`, or in neither.
pub fn set_weight(text: &str, id: &str, weight: Weight) -> Result<String> {
    let mut doc: DocumentMut = text.parse().context("reading the config")?;
    if !doc.contains_key("saver") {
        // Appended as text: a table toml_edit inserts lands above the
        // file's trailing comments.
        let sep = if text.is_empty() || text.ends_with("\n\n") {
            ""
        } else if text.ends_with('\n') {
            "\n"
        } else {
            "\n\n"
        };
        doc = format!("{text}{sep}[saver]\n").parse().context("reading the config")?;
    }
    let saver = doc["saver"].as_table_mut().context("[saver] is not a table")?;
    let listed = strings(saver.get("hacks"));
    if !listed.is_empty() && weight != Weight::Never && !listed.iter().any(|h| h == id) {
        push(saver, "hacks", id);
    }
    remove(saver, "skip", id);
    remove(saver, "often", id);
    match weight {
        Weight::Never => push(saver, "skip", id),
        Weight::Often => push(saver, "often", id),
        Weight::Sometimes => {}
    }
    Ok(doc.to_string())
}

fn strings(item: Option<&Item>) -> Vec<String> {
    item.and_then(|i| i.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

fn push(table: &mut Table, key: &str, id: &str) {
    if !table.get(key).is_some_and(|i| i.is_array()) {
        table[key] = toml_edit::value(Array::new());
    }
    if let Some(a) = table[key].as_array_mut()
        && !a.iter().any(|v| v.as_str() == Some(id))
    {
        a.push(id);
    }
}

fn remove(table: &mut Table, key: &str, id: &str) {
    if let Some(a) = table.get_mut(key).and_then(|i| i.as_array_mut()) {
        a.retain(|v: &Value| v.as_str() != Some(id));
    }
}

/// The new text of the config at `path` with `id` set to `weight`, and the
/// config it parses to. Nothing is written: the caller checks the rotation
/// first, then calls [`write`].
pub fn plan_weight(path: &Path, id: &str, weight: Weight) -> Result<(String, Config)> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    let new = set_weight(&text, id, weight)?;
    let cfg = Config::parse(&new).with_context(|| format!("the edit to {}", path.display()))?;
    Ok((new, cfg))
}

/// Writes `text` to the config at `path` atomically. A config that is a
/// symlink (a stowed dot-files package) stays one: the file it points to is
/// replaced.
pub fn write(path: &Path, text: &str) -> Result<()> {
    let real: PathBuf = match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_symlink() => std::fs::canonicalize(path)
            .with_context(|| format!("following the link at {}", path.display()))?,
        _ => path.to_path_buf(),
    };
    if let Some(dir) = real.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let tmp = real.with_extension("toml.tmp");
    std::fs::write(&tmp, text).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, &real).with_context(|| format!("writing {}", real.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHIPPED: &str = include_str!("../../../packaging/examples/config.toml");

    fn saver(text: &str) -> crate::config::Saver {
        Config::parse(text).unwrap().saver
    }

    #[test]
    fn the_switch_and_star_round_trip_and_keep_comments() {
        let off = set_weight(SHIPPED, "starfield", Weight::Never).unwrap();
        assert_eq!(saver(&off).weight("starfield"), Weight::Never);
        assert_eq!(saver(&off).weight("night-mail"), Weight::Sometimes);
        assert!(off.contains("# Hacks left out of the rotation"), "comments stay");
        let often = set_weight(&off, "starfield", Weight::Often).unwrap();
        let s = saver(&often);
        assert_eq!(s.weight("starfield"), Weight::Often);
        assert!(s.skip.is_empty());
        let back = set_weight(&often, "starfield", Weight::Sometimes).unwrap();
        assert_eq!(saver(&back), saver(SHIPPED));
    }

    #[test]
    fn an_empty_or_missing_file_gets_a_saver_table() {
        let t = set_weight("", "lava-drift", Weight::Often).unwrap();
        assert_eq!(saver(&t).often, ["lava-drift"]);
        let t = set_weight("[line]\nsaver = \"20m\"\n", "lava-drift", Weight::Never).unwrap();
        let cfg = Config::parse(&t).unwrap();
        assert_eq!(cfg.saver.skip, ["lava-drift"]);
        assert_eq!(cfg.line.saver.to_string(), "20m");
    }

    #[test]
    fn turning_on_a_hack_outside_an_explicit_list_adds_it() {
        let t = "[saver]\nhacks = [\"starfield\"]\n";
        assert_eq!(saver(t).weight("lava-drift"), Weight::Never);
        let on = set_weight(t, "lava-drift", Weight::Sometimes).unwrap();
        assert_eq!(saver(&on).hacks, ["starfield", "lava-drift"]);
        assert_eq!(saver(&on).weight("lava-drift"), Weight::Sometimes);
    }

    #[cfg(unix)]
    #[test]
    fn writes_through_a_symlink() {
        let dir = std::env::temp_dir().join(format!("layover-edit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("dots")).unwrap();
        let real = dir.join("dots/layover.toml");
        std::fs::write(&real, "# mine\n").unwrap();
        let link = dir.join("layover.toml");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let (text, cfg) = plan_weight(&link, "starfield", Weight::Never).unwrap();
        assert_eq!(cfg.saver.skip, ["starfield"]);
        write(&link, &text).unwrap();
        assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert!(std::fs::read_to_string(&real).unwrap().starts_with("# mine"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
