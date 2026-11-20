//! The line: the other tools on the desk, read from the lamp each one prints
//! for waybar (text, class, tooltip). The daemon runs their `bar` commands
//! and hands the lines here; everything in this file is pure.
//!
//! Privacy: a row on the Departure Board carries states and counts only.
//! Song titles, meeting names, secret names and task text never leave the
//! lamp line: nothing here copies free text from one into a row.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A tool Layover reads. The order is the board's row order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Feed {
    Timetable,
    Switchyard,
    Waybill,
    SignalBox,
    Roundhouse,
    Tablet,
    Logbook,
    Tannoy,
}

impl Feed {
    pub const ALL: [Feed; 8] = [
        Feed::Timetable,
        Feed::Switchyard,
        Feed::Waybill,
        Feed::SignalBox,
        Feed::Roundhouse,
        Feed::Tablet,
        Feed::Logbook,
        Feed::Tannoy,
    ];

    /// The config key, and the name in logs.
    pub fn key(self) -> &'static str {
        match self {
            Feed::Timetable => "timetable",
            Feed::Switchyard => "switchyard",
            Feed::Waybill => "waybill",
            Feed::SignalBox => "signal_box",
            Feed::Roundhouse => "roundhouse",
            Feed::Tablet => "tablet",
            Feed::Logbook => "logbook",
            Feed::Tannoy => "tannoy",
        }
    }

    /// The board's FROM column.
    pub fn board_name(self) -> &'static str {
        match self {
            Feed::Timetable => "TIMETABLE",
            Feed::Switchyard => "SWITCHYARD",
            Feed::Waybill => "WAYBILL",
            Feed::SignalBox => "SIGNAL BOX",
            Feed::Roundhouse => "ROUNDHOUSE",
            Feed::Tablet => "TABLET",
            Feed::Logbook => "LOGBOOK",
            Feed::Tannoy => "TANNOY",
        }
    }
}

/// One lamp line as waybar reads it. `class` may be a string or a list.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LampLine {
    /// The text with Pango markup removed.
    pub text: String,
    pub classes: Vec<String>,
    pub tooltip: String,
}

impl LampLine {
    pub fn has(&self, class: &str) -> bool {
        self.classes.iter().any(|c| c == class)
    }
}

#[derive(Deserialize)]
struct RawLamp {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    class: Option<serde_json::Value>,
    #[serde(default)]
    tooltip: Option<String>,
}

/// Read one line of a `bar` stream. None for anything that isn't a lamp.
pub fn parse_lamp(line: &str) -> Option<LampLine> {
    let raw: RawLamp = serde_json::from_str(line.trim()).ok()?;
    let classes = match raw.class {
        Some(serde_json::Value::String(s)) => vec![s],
        Some(serde_json::Value::Array(a)) => {
            a.into_iter().filter_map(|v| v.as_str().map(str::to_string)).collect()
        }
        _ => Vec::new(),
    };
    Some(LampLine {
        text: strip_markup(raw.text.as_deref().unwrap_or_default()),
        classes,
        tooltip: strip_markup(raw.tooltip.as_deref().unwrap_or_default()),
    })
}

/// Drop Pango tags and the few entities waybar text uses.
fn strip_markup(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&#39;", "'")
}

/// The first whole number in `s`.
fn first_number(s: &str) -> Option<u32> {
    let digits: String =
        s.chars().skip_while(|c| !c.is_ascii_digit()).take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// The number in a "… in 7m" or "… 9m left" phrase, without the title
/// before it.
fn minutes_after(s: &str, before: &str) -> Option<u32> {
    let at = s.rfind(before)?;
    let rest = &s[at + before.len()..];
    let n: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if n.is_empty() || !rest[n.len()..].starts_with('m') {
        return None;
    }
    n.parse().ok()
}

fn minutes_before(s: &str, after: &str) -> Option<u32> {
    let at = s.find(after)?;
    let head = &s[..at];
    let n: String = head
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    n.parse().ok()
}

/// A row's mood, which colors its STATUS column.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tone {
    #[default]
    Calm,
    Busy,
    Alert,
    Quiet,
}

/// One row on the Departure Board. Uppercase, states and counts only.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub what: String,
    pub from: String,
    pub status: String,
    pub tone: Tone,
}

/// Longest WHAT and STATUS the board has room for.
pub const WHAT_MAX: usize = 22;
pub const STATUS_MAX: usize = 10;

fn row(feed: Feed, what: impl Into<String>, status: impl Into<String>, tone: Tone) -> Row {
    let cut = |s: String, n: usize| s.chars().take(n).collect::<String>();
    Row {
        what: cut(what.into(), WHAT_MAX),
        from: feed.board_name().into(),
        status: cut(status.into(), STATUS_MAX),
        tone,
    }
}

/// What one lamp says, in the terms Layover cares about.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reading {
    pub row: Option<Row>,
    /// Logbook is recording or dictating.
    pub on_air: bool,
    /// Timetable says a meeting is soon (its 10 minutes) or starting.
    pub meeting_soon: bool,
    /// Switchyard has a heavy build on the main line or waiting for it.
    pub heavy_build: bool,
    /// Roundhouse warns about heat.
    pub hot: bool,
}

/// Read one tool's lamp.
pub fn read(feed: Feed, lamp: &LampLine) -> Reading {
    let mut r = Reading::default();
    match feed {
        Feed::Timetable => {
            r.row = Some(if lamp.has("now") {
                r.meeting_soon = true;
                row(feed, "MEETING STARTS", "NOW", Tone::Alert)
            } else if lamp.has("soon") {
                r.meeting_soon = true;
                let n = minutes_after(&lamp.text, " in ").map(|n| format!("IN {n}M"));
                row(feed, "MEETING", n.unwrap_or_else(|| "SOON".into()), Tone::Busy)
            } else if lamp.has("in") {
                let n = minutes_before(&lamp.text, "m left").map(|n| format!("{n}M LEFT"));
                row(feed, "IN A MEETING", n.unwrap_or_else(|| "NOW".into()), Tone::Busy)
            } else if lamp.has("next") {
                let n = minutes_after(&lamp.text, " in ").map(|n| format!("IN {n}M"));
                row(feed, "MEETING", n.unwrap_or_else(|| "LATER".into()), Tone::Calm)
            } else if lamp.has("focus") {
                row(feed, "FOCUS BLOCK", "ON", Tone::Calm)
            } else if lamp.has("own") {
                row(feed, "YOUR OWN TIME", "ON", Tone::Calm)
            } else if lamp.has("offline") {
                row(feed, "CALENDAR", "OFFLINE", Tone::Quiet)
            } else {
                row(feed, "NO MEETING SOON", "FREE", Tone::Calm)
            });
        }
        Feed::Switchyard => {
            let n = first_number(&lamp.text).filter(|n| *n > 1);
            let builds = n.map(|n| format!("{n} BUILDS")).unwrap_or_else(|| "BUILD".into());
            r.row = Some(if lamp.has("failed") {
                row(feed, builds, "FAILED", Tone::Alert)
            } else if lamp.has("building") {
                r.heavy_build = true;
                row(feed, builds, "BUILDING", Tone::Busy)
            } else if lamp.has("queued") {
                r.heavy_build = true;
                row(feed, builds, "QUEUED", Tone::Busy)
            } else if lamp.has("running") {
                let tasks = n.map(|n| format!("{n} TASKS")).unwrap_or_else(|| "TASK".into());
                row(feed, tasks, "RUNNING", Tone::Calm)
            } else if lamp.has("ok") {
                row(feed, builds, "OK", Tone::Calm)
            } else if lamp.has("offline") {
                row(feed, "BUILDS", "OFFLINE", Tone::Quiet)
            } else {
                row(feed, "BUILDS", "ALL QUIET", Tone::Calm)
            });
        }
        Feed::Waybill => {
            let waiting = lamp
                .tooltip
                .lines()
                .filter(|l| l.contains("on you") && l.contains("wait"))
                .find_map(|l| minutes_before(l, " task"));
            r.row = Some(if lamp.has("error") || lamp.has("offline") {
                row(feed, "TASKS", "OFFLINE", Tone::Quiet)
            } else {
                match waiting.or_else(|| first_number(&lamp.text)) {
                    Some(1) => row(feed, "1 TASK WAITS ON YOU", "WAITING", Tone::Busy),
                    Some(n) if n > 0 => {
                        row(feed, format!("{n} TASKS WAIT ON YOU"), "WAITING", Tone::Busy)
                    }
                    _ => row(feed, "NOTHING WAITS ON YOU", "CLEAR", Tone::Calm),
                }
            });
        }
        Feed::SignalBox => {
            let n = first_number(&lamp.text).unwrap_or(0);
            r.row = Some(if lamp.has("asking") {
                row(feed, "AGENT ASKS FOR A KEY", "TOUCH KEY", Tone::Alert)
            } else if lamp.has("missed") {
                row(feed, "A REQUEST", "MISSED", Tone::Alert)
            } else if lamp.has("ending") {
                row(feed, "GRANT", "ENDING", Tone::Busy)
            } else if lamp.has("live") && n > 0 {
                let what = if n == 1 { "1 GRANT".to_string() } else { format!("{n} GRANTS") };
                row(feed, what, "LIVE", Tone::Busy)
            } else if lamp.has("error") || lamp.has("offline") {
                row(feed, "SECRETS", "OFFLINE", Tone::Quiet)
            } else if lamp.has("locked") {
                row(feed, "SECRETS", "LOCKED", Tone::Calm)
            } else {
                row(feed, "SECRETS", "QUIET", Tone::Calm)
            });
        }
        Feed::Roundhouse => {
            let warned = lamp.has("heads-up") || lamp.has("act");
            r.hot = warned
                && lamp
                    .tooltip
                    .lines()
                    .any(|l| l.trim_start().starts_with('•') && l.contains("°C"));
            r.row = Some(if lamp.has("act") {
                row(feed, "MACHINE", "NEEDS YOU", Tone::Alert)
            } else if lamp.has("heads-up") {
                row(feed, "MACHINE", "HEADS UP", Tone::Busy)
            } else if lamp.has("offline") {
                row(feed, "MACHINE", "OFFLINE", Tone::Quiet)
            } else {
                row(feed, "MACHINE", "FIT TO RUN", Tone::Calm)
            });
        }
        Feed::Tablet => {
            r.row = Some(if lamp.has("held") {
                row(feed, "WORK VPN", "UP", Tone::Calm)
            } else if lamp.has("stale") || lamp.has("degraded") {
                row(feed, "WORK VPN", "STALE", Tone::Busy)
            } else if lamp.has("dropped") || lamp.has("failed") || lamp.has("broken") {
                row(feed, "WORK VPN", "DOWN", Tone::Alert)
            } else if lamp.has("connecting") || lamp.has("signin") || lamp.has("asking") {
                row(feed, "WORK VPN", "CONNECTING", Tone::Busy)
            } else if lamp.has("offline") {
                row(feed, "WORK VPN", "OFFLINE", Tone::Quiet)
            } else {
                row(feed, "WORK VPN", "OFF", Tone::Quiet)
            });
        }
        Feed::Logbook => {
            r.on_air = lamp.has("recording") || lamp.has("dictating");
            r.row = Some(if lamp.has("recording") {
                row(feed, "ON AIR", "RECORDING", Tone::Alert)
            } else if lamp.has("dictating") {
                row(feed, "ON AIR", "DICTATING", Tone::Alert)
            } else if lamp.has("processing") || lamp.has("transcribing") {
                row(feed, "TRANSCRIPT", "WORKING", Tone::Busy)
            } else if lamp.has("mic") {
                row(feed, "MIC", "IN USE", Tone::Busy)
            } else if lamp.has("offline") {
                row(feed, "MIC", "OFFLINE", Tone::Quiet)
            } else {
                row(feed, "MIC", "OFF AIR", Tone::Calm)
            });
        }
        Feed::Tannoy => {
            r.row = if lamp.has("playing") {
                Some(row(feed, "MUSIC", "PLAYING", Tone::Calm))
            } else if lamp.has("paused") {
                Some(row(feed, "MUSIC", "PAUSED", Tone::Quiet))
            } else if lamp.has("hidden") {
                Some(row(feed, "MUSIC", "HIDDEN", Tone::Quiet))
            } else {
                None
            };
        }
    }
    r
}

/// Everything the line says, put together.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Desk {
    /// The board's rows, in feed order.
    pub rows: Vec<Row>,
    /// Logbook is on air (holds the saver, the lock and the dark).
    pub on_air: bool,
    /// A meeting is soon (holds the saver).
    pub meeting_soon: bool,
    /// Why the saver should draw in cheap mode, if it should.
    pub cheap: Option<String>,
}

/// Put the readings together. `cheap` is `[feeds] cheap`.
pub fn desk(readings: &BTreeMap<Feed, Reading>, cheap: bool) -> Desk {
    let mut d =
        Desk { rows: readings.values().filter_map(|r| r.row.clone()).collect(), ..Desk::default() };
    d.on_air = readings.values().any(|r| r.on_air);
    d.meeting_soon = readings.values().any(|r| r.meeting_soon);
    if cheap {
        let heavy = readings.values().any(|r| r.heavy_build);
        let hot = readings.values().any(|r| r.hot);
        d.cheap = match (heavy, hot) {
            (true, true) => Some("a heavy build runs and the machine is hot".into()),
            (true, false) => Some("a heavy build runs".into()),
            (false, true) => Some("the machine is hot".into()),
            (false, false) => None,
        };
    }
    d
}

/// The saver's subscription: the board's rows and whether to draw cheap.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineUpdate {
    pub rows: Vec<Row>,
    pub cheap: bool,
}

/// Cheap mode: what the saver gives up while a heavy build or a hot machine
/// needs the GPU. Motion stays at full speed, so rule one's dwell is as before.
pub const CHEAP_FPS_DIVISOR: u32 = 2;
pub const CHEAP_SCALE: f32 = 0.5;
pub const CHEAP_DIM: f32 = 0.75;

#[cfg(test)]
mod tests {
    use super::*;

    fn lamp(name: &str) -> LampLine {
        let path = format!("{}/fixtures/lamps/{name}.json", env!("CARGO_MANIFEST_DIR"));
        parse_lamp(&std::fs::read_to_string(&path).unwrap()).unwrap_or_else(|| panic!("{name}"))
    }

    fn status(feed: Feed, name: &str) -> (String, String, Tone) {
        let r = read(feed, &lamp(name)).row.unwrap();
        (r.what, r.status, r.tone)
    }

    #[test]
    fn class_may_be_a_string_or_a_list_and_markup_goes() {
        let l = lamp("timetable-free");
        assert_eq!(l.classes, ["free"]);
        assert_eq!(l.text, "Fri Nov 20  10:19");
        assert_eq!(lamp("yard-idle").classes, ["idle"]);
        assert!(parse_lamp("{not json").is_none());
        assert!(parse_lamp("").is_none());
    }

    #[test]
    fn timetable_counts_down_without_the_title() {
        assert_eq!(
            status(Feed::Timetable, "timetable-soon"),
            ("MEETING".into(), "IN 7M".into(), Tone::Busy)
        );
        assert!(read(Feed::Timetable, &lamp("timetable-soon")).meeting_soon);
        assert!(read(Feed::Timetable, &lamp("timetable-now")).meeting_soon);
        assert_eq!(status(Feed::Timetable, "timetable-next").1, "IN 34M");
        assert!(!read(Feed::Timetable, &lamp("timetable-next")).meeting_soon);
        assert_eq!(status(Feed::Timetable, "timetable-free").1, "FREE");
    }

    #[test]
    fn switchyard_heavy_builds_and_failures() {
        let b = read(Feed::Switchyard, &lamp("yard-building"));
        assert!(b.heavy_build);
        assert_eq!(b.row.unwrap().what, "2 BUILDS");
        assert_eq!(status(Feed::Switchyard, "yard-failed").1, "FAILED");
        assert_eq!(status(Feed::Switchyard, "yard-idle").1, "ALL QUIET");
    }

    #[test]
    fn waybill_counts_what_waits_on_you() {
        assert_eq!(status(Feed::Waybill, "waybill-needs-you").0, "33 TASKS WAIT ON YOU");
    }

    #[test]
    fn signal_box_asks_for_a_touch() {
        assert_eq!(status(Feed::SignalBox, "broker-asking").1, "TOUCH KEY");
        assert_eq!(status(Feed::SignalBox, "broker-live").0, "2 GRANTS");
    }

    #[test]
    fn roundhouse_is_hot_only_for_heat() {
        assert!(read(Feed::Roundhouse, &lamp("rh-act-hot")).hot);
        assert!(!read(Feed::Roundhouse, &lamp("rh-heads-up-disk")).hot);
    }

    #[test]
    fn logbook_on_air() {
        assert!(read(Feed::Logbook, &lamp("logbook-recording")).on_air);
        assert!(!read(Feed::Logbook, &lamp("logbook-off")).on_air);
    }

    #[test]
    fn tablet_and_tannoy() {
        assert_eq!(status(Feed::Tablet, "tablet-held").1, "UP");
        assert_eq!(status(Feed::Tannoy, "tannoy-paused").1, "PAUSED");
    }

    /// Privacy: no row carries free text from a lamp, only its own words.
    #[test]
    fn rows_never_copy_titles() {
        let pairs = [
            (Feed::Timetable, "timetable-soon"),
            (Feed::Timetable, "timetable-now"),
            (Feed::Timetable, "timetable-next"),
            (Feed::Tannoy, "tannoy-paused"),
            (Feed::Switchyard, "yard-failed"),
            (Feed::SignalBox, "broker-asking"),
            (Feed::SignalBox, "broker-live"),
        ];
        for (feed, name) in pairs {
            let r = read(feed, &lamp(name)).row.unwrap();
            let all = format!("{} {} {}", r.what, r.from, r.status).to_lowercase();
            for word in ["standup", "design", "review", "removed", "ledger", "artist", "title"] {
                assert!(!all.contains(word), "{name} leaked {word}: {all}");
            }
            assert!(r.what.chars().count() <= WHAT_MAX && r.status.chars().count() <= STATUS_MAX);
        }
    }

    #[test]
    fn the_desk_puts_it_together() {
        let mut m = BTreeMap::new();
        m.insert(Feed::Logbook, read(Feed::Logbook, &lamp("logbook-recording")));
        m.insert(Feed::Switchyard, read(Feed::Switchyard, &lamp("yard-building")));
        m.insert(Feed::Roundhouse, read(Feed::Roundhouse, &lamp("rh-act-hot")));
        let d = desk(&m, true);
        assert!(d.on_air);
        assert_eq!(d.cheap.as_deref(), Some("a heavy build runs and the machine is hot"));
        assert_eq!(
            d.rows.iter().map(|r| r.from.as_str()).collect::<Vec<_>>(),
            ["SWITCHYARD", "ROUNDHOUSE", "LOGBOOK"]
        );
        assert_eq!(desk(&m, false).cheap, None);
    }
}
