//! What the drawer shows: the snapshot the daemon streams to `layover-board`
//! on every change, and the events that open and close it.

use crate::config::{Config, LockAt, Weight};
use crate::lamp::Lamp;
use crate::span::Span;
use bar_anchor::Anchor;
use serde::{Deserialize, Serialize};

/// Everything the drawer draws, already worded.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    pub lamp: Lamp,
    /// `armed`, `held`, `saver`, `dark` or `loose`: the lamp's class.
    pub state: String,
    /// The state in a word or two: "Armed", "Held", "Saver running".
    pub headline: String,
    /// Why, in a sentence: the lamp's first tooltip line.
    pub reason: String,
    /// "Saver after 15m · lock with the dark · screens off after 1h".
    pub summary: String,
    pub stations: Vec<StationView>,
    pub loosened: Vec<LooseView>,
    /// A `layover hold` runs: the drawer offers Release instead of Hold.
    pub manual_hold: bool,
    pub locked: bool,
    /// The hack on screen while the saver runs.
    pub hack: Option<String>,
    /// Why the saver draws in cheap mode, when it does.
    #[serde(default)]
    pub cheap: Option<String>,
    pub hacks: Vec<HackView>,
    /// Newest first.
    pub history: Vec<HistoryView>,
}

/// One station on the idle line as the drawer's rail shows it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StationView {
    pub name: String,
    /// "15m", "with the dark", "off".
    pub at: String,
    pub on: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LooseView {
    pub key: String,
    pub value: String,
    pub shipped: String,
    pub why: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HackView {
    pub id: String,
    pub name: String,
    /// What it looks like, in a sentence.
    pub about: String,
    /// The xscreensaver hacks it follows ("After Lavalite by Jamie
    /// Zawinski."), or empty.
    #[serde(default)]
    pub credit: String,
    /// How often it comes up: the drawer's switch and star.
    pub weight: Weight,
    /// Its family for the drawer's filters: Fields, 3D, Growth, Particles,
    /// Lines or Text.
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryView {
    /// Local time, `14:02:11`.
    pub time: String,
    pub what: String,
    pub why: String,
}

/// From the daemon to the drawer, one per line.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "lowercase")]
pub enum BoardEvent {
    Snapshot { snapshot: Box<Snapshot> },
    Toggle { anchor: Option<Anchor> },
    Show { anchor: Option<Anchor> },
    Hide,
}

/// The rail: saver, lock and dark as configured, plus what happens to a
/// still lock screen.
pub fn stations(cfg: &Config) -> Vec<StationView> {
    let span = |s: Span| match s {
        Span::After(_) => (s.to_string(), true),
        Span::Off => ("off".to_string(), false),
    };
    let (saver, saver_on) = span(cfg.line.saver);
    let (dark, dark_on) = span(cfg.line.dark);
    let (lock, lock_on) = match cfg.line.lock {
        LockAt::Dark => ("with the dark".to_string(), dark_on),
        LockAt::After(_) => (cfg.line.lock.to_string(), true),
        LockAt::Off => ("off".to_string(), false),
    };
    let (still, still_on) = span(cfg.line.locked_dark);
    vec![
        StationView { name: "Saver".into(), at: saver, on: saver_on },
        StationView { name: "Lock".into(), at: lock, on: lock_on },
        StationView { name: "Screens off".into(), at: dark, on: dark_on },
        StationView { name: "Lock screen off".into(), at: still, on: still_on },
    ]
}

/// A hack's one line split into what it looks like and whom it follows:
/// "Rings cross (after Interference by Hannu Mallat)." becomes "Rings
/// cross." and "After Interference by Hannu Mallat.".
pub fn split_about(about: &str) -> (String, String) {
    match about.split_once(" (after ") {
        Some((what, rest)) => {
            let who = rest.trim_end_matches('.').trim_end_matches(')');
            (format!("{what}."), format!("After {who}."))
        }
        None => (about.to_string(), String::new()),
    }
}

pub fn loosened(cfg: &Config) -> Vec<LooseView> {
    cfg.loosened()
        .into_iter()
        .map(|l| LooseView {
            key: l.key.into(),
            value: l.value,
            shipped: l.shipped,
            why: l.why.into(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_rail_is_honest_to_the_config() {
        let s = stations(&Config::default());
        let at: Vec<_> = s.iter().map(|v| (v.name.as_str(), v.at.as_str(), v.on)).collect();
        assert_eq!(
            at,
            [
                ("Saver", "15m", true),
                ("Lock", "with the dark", true),
                ("Screens off", "1h", true),
                ("Lock screen off", "1m", true)
            ]
        );
        let off = Config::parse("[line]\ndark = \"off\"\nsaver = \"off\"").unwrap();
        let s = stations(&off);
        assert!(!s[0].on && !s[2].on);
        assert!(!s[1].on, "a lock with the dark never comes when the dark is off");
    }

    #[test]
    fn credits_come_off_the_about_line() {
        assert_eq!(
            split_about("Rings cross into bands (after Interference by Hannu Mallat)."),
            (
                "Rings cross into bands.".to_string(),
                "After Interference by Hannu Mallat.".to_string()
            )
        );
        assert_eq!(
            split_about("Frost curtains over black mountains."),
            ("Frost curtains over black mountains.".to_string(), String::new())
        );
    }

    #[test]
    fn events_read_back() {
        for ev in [
            BoardEvent::Hide,
            BoardEvent::Toggle { anchor: None },
            BoardEvent::Snapshot { snapshot: Box::default() },
        ] {
            let line = serde_json::to_string(&ev).unwrap();
            assert_eq!(serde_json::from_str::<BoardEvent>(&line).unwrap(), ev);
        }
        assert!(serde_json::to_string(&BoardEvent::Hide).unwrap().contains(r#""event":"hide""#));
    }
}
