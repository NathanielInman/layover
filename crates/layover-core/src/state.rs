//! The idle line as a pure state machine: events in, effects out.
//!
//! The daemon turns Wayland idle notifications, socket commands and child
//! exits into [`Event`]s, gathers the holds when a station is reached, and
//! carries out the [`Effect`]s. Every rule about what happens when lives here
//! with a test; the daemon only does I/O.

use crate::board::{self, HackView, HistoryView, LooseView, Snapshot, StationView};
use crate::config::{AudioHold, Config, LockAt};
use crate::holds::HoldSnapshot;
use crate::lamp::Lamp;
use crate::span::{Span, format_duration};
use std::collections::{BTreeSet, VecDeque};
use std::time::Duration;

/// A point on the idle line. `LockedDark` is the short timeout that turns the
/// screens off while a lock screen sits still.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Station {
    Saver,
    Lock,
    Dark,
    LockedDark,
}

impl Station {
    fn name(self) -> &'static str {
        match self {
            Station::Saver => "The saver",
            Station::Lock => "The lock",
            Station::Dark | Station::LockedDark => "Screens off",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// An idle timeout passed. `holds` and `locked` are read at that moment.
    Reached { station: Station, holds: HoldSnapshot, locked: bool },
    /// A held station is due another look, with fresh holds.
    Retry { holds: HoldSnapshot, locked: bool },
    /// Input came back.
    Resumed,
    /// The saver process ended on its own (input dismissed it, or it failed).
    SaverExited,
    /// `layover hold`: hold the line for this many seconds.
    Hold { secs: u64 },
    /// `layover release`: end a manual hold.
    Release,
    /// `layover now`: start the saver now.
    Now,
    /// `layover stop`: stop the saver.
    Stop,
    /// Time passed; the daemon sends one every few seconds.
    Tick,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    StartSaver,
    StopSaver,
    Lock,
    ScreensOff,
    ScreensOn,
    /// Send a [`Event::Retry`] after this many seconds (replaces any earlier
    /// request).
    Retry {
        after: u64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Active,
    Saver,
    Dark,
}

/// How often a held station is checked again.
pub const RETRY_SECS: u64 = 60;

/// How many transitions the history keeps.
pub const HISTORY: usize = 50;

/// One transition for the drawer's History tab: what happened and why, at
/// a time on the daemon's monotonic clock.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub at: u64,
    pub what: String,
    pub why: String,
}

#[derive(Clone, Debug)]
struct Rules {
    lock: LockAt,
    audio: AudioHold,
    mic: bool,
    inhibitors: bool,
    locked_dark: Option<u64>,
    saver_span: Span,
    dark_span: Span,
    locked_dark_span: Span,
    summary: String,
    loose: Vec<String>,
    stations: Vec<StationView>,
    loose_views: Vec<LooseView>,
}

#[derive(Clone, Debug)]
pub struct Model {
    rules: Rules,
    phase: Phase,
    locked: bool,
    pending: BTreeSet<Station>,
    held_by: Option<String>,
    manual_until: Option<u64>,
    dark_due: Option<u64>,
    now: u64,
    history: VecDeque<Entry>,
    /// The hold last written to the history, so a retry that finds the same
    /// hold every minute writes it once.
    noted_hold: Option<String>,
    /// Set while a retry re-runs held stations: they go ahead because the
    /// hold ended, not because of the idle timeout.
    retrying: bool,
}

impl Model {
    pub fn new(cfg: &Config) -> Model {
        Model {
            rules: Rules {
                lock: cfg.line.lock,
                audio: cfg.holds.audio,
                mic: cfg.holds.mic,
                inhibitors: cfg.holds.inhibitors,
                locked_dark: match cfg.line.locked_dark {
                    Span::After(d) => Some(d.as_secs()),
                    Span::Off => None,
                },
                saver_span: cfg.line.saver,
                dark_span: cfg.line.dark,
                locked_dark_span: cfg.line.locked_dark,
                summary: cfg.summary(),
                loose: cfg.loosened().iter().map(|l| format!("{} = {}", l.key, l.value)).collect(),
                stations: board::stations(cfg),
                loose_views: board::loosened(cfg),
            },
            phase: Phase::Active,
            locked: false,
            pending: BTreeSet::new(),
            held_by: None,
            manual_until: None,
            dark_due: None,
            now: 0,
            history: VecDeque::new(),
            noted_hold: None,
            retrying: false,
        }
    }

    fn note(&mut self, what: &str, why: impl Into<String>) {
        if self.history.len() == HISTORY {
            self.history.pop_front();
        }
        self.history.push_back(Entry { at: self.now, what: what.into(), why: why.into() });
    }

    /// The transitions so far, oldest first.
    pub fn history(&self) -> impl DoubleEndedIterator<Item = &Entry> {
        self.history.iter()
    }

    /// The drawer's snapshot. `clock` turns a time on the monotonic clock
    /// into local time; `hack` is the one on screen, if the saver runs.
    pub fn snapshot(
        &self,
        clock: &dyn Fn(u64) -> String,
        hack: Option<String>,
        hacks: Vec<HackView>,
    ) -> Snapshot {
        let lamp = self.lamp();
        let headline = match lamp.class.as_str() {
            "saver" => "Saver running",
            "dark" => "Screens off",
            "held" => "Held",
            _ => "Armed",
        };
        Snapshot {
            state: lamp.class.clone(),
            headline: headline.into(),
            reason: lamp.tooltip.lines().next().unwrap_or_default().to_string(),
            summary: self.rules.summary.clone(),
            stations: self.rules.stations.clone(),
            loosened: self.rules.loose_views.clone(),
            manual_hold: self.manual_left().is_some(),
            locked: self.locked,
            hack: if self.phase == Phase::Saver { hack } else { None },
            hacks,
            history: self
                .history
                .iter()
                .rev()
                .map(|e| HistoryView {
                    time: clock(e.at),
                    what: e.what.clone(),
                    why: e.why.clone(),
                })
                .collect(),
            lamp,
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn locked(&self) -> bool {
        self.locked
    }

    /// True while a station waits on a hold.
    pub fn waiting(&self) -> bool {
        !self.pending.is_empty()
    }

    /// Apply one event at `now` (seconds on a monotonic clock).
    pub fn step(&mut self, now: u64, event: Event) -> Vec<Effect> {
        self.now = now;
        let mut out = Vec::new();
        match event {
            Event::Reached { station, holds, locked } => {
                self.locked = locked;
                self.pending.remove(&station);
                self.reach(station, &holds, &mut out);
            }
            Event::Retry { holds, locked } => {
                self.locked = locked;
                let was = std::mem::take(&mut self.pending);
                self.held_by = None;
                self.retrying = true;
                // Latest station first: when the dark may go ahead, the
                // saver it would replace never starts.
                for st in [Station::LockedDark, Station::Dark, Station::Lock, Station::Saver] {
                    if was.contains(&st) {
                        self.reach(st, &holds, &mut out);
                    }
                }
                self.retrying = false;
            }
            Event::Resumed => {
                self.pending.clear();
                self.held_by = None;
                self.noted_hold = None;
                self.dark_due = None;
                match self.phase {
                    Phase::Saver => {
                        out.push(Effect::StopSaver);
                        self.note("Saver dismissed", "input came back");
                    }
                    Phase::Dark => {
                        out.push(Effect::ScreensOn);
                        self.note("Screens on", "input came back");
                    }
                    Phase::Active => {}
                }
                self.phase = Phase::Active;
            }
            Event::SaverExited => {
                if self.phase == Phase::Saver {
                    self.phase = Phase::Active;
                    self.note("Saver ended", "it exited on its own");
                }
            }
            Event::Hold { secs } => {
                self.manual_until = Some(now + secs);
                self.note("Held", format!("by you for {}", round_minutes(secs)));
            }
            Event::Release => {
                if self.manual_until.take().is_some() {
                    self.note("Hold released", "you released it");
                }
                if !self.pending.is_empty() {
                    out.push(Effect::Retry { after: 0 });
                }
            }
            Event::Now => {
                if self.phase == Phase::Active && !self.locked {
                    self.phase = Phase::Saver;
                    out.push(Effect::StartSaver);
                    self.note("Saver started", "you asked");
                }
            }
            Event::Stop => {
                if self.phase == Phase::Saver {
                    self.phase = Phase::Active;
                    out.push(Effect::StopSaver);
                    self.note("Saver stopped", "you asked");
                }
            }
            Event::Tick => {
                if let Some(until) = self.manual_until
                    && until <= now
                {
                    self.manual_until = None;
                    self.note("Hold ran out", "its time was up");
                    if !self.pending.is_empty() {
                        out.push(Effect::Retry { after: 0 });
                    }
                }
                if let Some(due) = self.dark_due
                    && due <= now
                {
                    self.dark_due = None;
                    self.pending.insert(Station::LockedDark);
                    out.push(Effect::Retry { after: 0 });
                }
            }
        }
        dedup_retries(&mut out);
        out
    }

    fn reach(&mut self, station: Station, holds: &HoldSnapshot, out: &mut Vec<Effect>) {
        match station {
            Station::Saver => {
                if self.phase != Phase::Active || self.locked {
                    return;
                }
                if let Some(why) = self.hold_reason(station, holds) {
                    return self.hold(station, why, out);
                }
                self.phase = Phase::Saver;
                out.push(Effect::StartSaver);
                let why = self.why_now(self.rules.saver_span);
                self.note("Saver started", why);
                self.noted_hold = None;
            }
            Station::Lock => {
                if self.locked {
                    return;
                }
                if let Some(why) = self.hold_reason(station, holds) {
                    return self.hold(station, why, out);
                }
                self.lock_now(out);
            }
            Station::Dark => {
                if self.phase == Phase::Dark {
                    return;
                }
                if let Some(why) = self.hold_reason(station, holds) {
                    return self.hold(station, why, out);
                }
                let why = self.why_now(self.rules.dark_span);
                self.go_dark(out, why);
            }
            Station::LockedDark => {
                if !self.locked || self.phase == Phase::Dark {
                    return;
                }
                if let Some(why) = self.hold_reason(station, holds) {
                    return self.hold(station, why, out);
                }
                let why = if self.retrying {
                    "the lock screen sat still".to_string()
                } else {
                    format!("the lock screen sat still for {}", self.rules.locked_dark_span)
                };
                self.go_dark(out, why);
            }
        }
    }

    /// Why a station went ahead: its idle timeout, or a hold that ended.
    fn why_now(&self, after: Span) -> String {
        if self.retrying { "nothing holds it now".into() } else { format!("{after} idle") }
    }

    fn lock_now(&mut self, out: &mut Vec<Effect>) {
        out.push(Effect::Lock);
        self.locked = true;
        let why = match self.rules.lock {
            LockAt::After(d) if !self.retrying => format!("{} idle", format_duration(d)),
            _ => "nothing holds it now".into(),
        };
        self.note("Locked", why);
        self.noted_hold = None;
        if self.phase == Phase::Saver {
            // The lock screen covers the overlay; don't draw what nobody sees.
            out.push(Effect::StopSaver);
            self.phase = Phase::Active;
        }
        if self.phase != Phase::Dark
            && let Some(after) = self.rules.locked_dark
        {
            self.dark_due = Some(self.now + after);
        }
    }

    fn go_dark(&mut self, out: &mut Vec<Effect>, why: String) {
        if self.rules.lock == LockAt::Dark && !self.locked {
            out.push(Effect::Lock);
            self.locked = true;
            self.note("Locked", "with the dark");
        }
        if self.phase == Phase::Saver {
            out.push(Effect::StopSaver);
        }
        self.phase = Phase::Dark;
        out.push(Effect::ScreensOff);
        self.note("Screens off", why);
        self.pending.clear();
        self.held_by = None;
        self.noted_hold = None;
        self.dark_due = None;
    }

    fn hold(&mut self, station: Station, why: String, out: &mut Vec<Effect>) {
        let newly = !self.pending.contains(&station);
        self.pending.insert(station);
        if newly && self.noted_hold.as_deref() != Some(why.as_str()) {
            self.note(&format!("{} held", station.name()), why.clone());
            self.noted_hold = Some(why.clone());
        }
        self.held_by = Some(why);
        out.push(Effect::Retry { after: RETRY_SECS });
    }

    fn manual_left(&self) -> Option<u64> {
        self.manual_until.filter(|u| *u > self.now).map(|u| u - self.now)
    }

    fn hold_reason(&self, station: Station, h: &HoldSnapshot) -> Option<String> {
        if let Some(left) = self.manual_left() {
            return Some(format!("held by you for {} more", round_minutes(left)));
        }
        if self.rules.inhibitors && !h.inhibitors.is_empty() {
            return Some(format!("{} is keeping the screen on", h.inhibitors.join(", ")));
        }
        if self.rules.mic && h.mic {
            return Some("a microphone is recording".into());
        }
        let audio_holds = match self.rules.audio {
            AudioHold::All => true,
            AudioHold::Dark => matches!(station, Station::Dark | Station::LockedDark),
            AudioHold::Off => false,
        };
        if audio_holds && h.audio {
            return Some("audio is playing".into());
        }
        None
    }

    /// The lamp for waybar.
    pub fn lamp(&self) -> Lamp {
        let mut lines = Vec::new();
        let class = match self.phase {
            Phase::Saver => {
                lines.push("A hack is running. Any input dismisses it.".to_string());
                lines.push(self.rules.summary.clone());
                "saver"
            }
            Phase::Dark => {
                lines.push("The screens are off.".to_string());
                lines.push(self.rules.summary.clone());
                "dark"
            }
            Phase::Active => {
                if let Some(left) = self.manual_left() {
                    lines.push(format!(
                        "Held by you for {} more. `layover release` ends it.",
                        round_minutes(left)
                    ));
                    lines.push(self.rules.summary.clone());
                    "held"
                } else if let (Some(st), Some(why)) = (self.pending.last(), &self.held_by) {
                    lines.push(format!(
                        "{} is held: {why}. Checking again every minute.",
                        st.name()
                    ));
                    lines.push(self.rules.summary.clone());
                    "held"
                } else {
                    lines.push(self.rules.summary.clone());
                    "armed"
                }
            }
        };
        let class = if !self.rules.loose.is_empty() {
            lines.push(format!(
                "Looser than shipped: {}. `layover check` says what each risks.",
                self.rules.loose.join(", ")
            ));
            if class == "armed" { "loose" } else { class }
        } else {
            class
        };
        Lamp::new(class, lines.join("\n"))
    }
}

fn round_minutes(secs: u64) -> String {
    let mins = secs.div_ceil(60).max(1);
    format_duration(Duration::from_secs(mins * 60))
}

/// Keep only the last retry request; the daemon holds one deadline.
fn dedup_retries(out: &mut Vec<Effect>) {
    let last = out.iter().rposition(|e| matches!(e, Effect::Retry { .. }));
    if let Some(last) = last {
        let mut i = 0;
        out.retain(|e| {
            let keep = !matches!(e, Effect::Retry { .. }) || i == last;
            i += 1;
            keep
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Effect::*;

    fn model(toml: &str) -> Model {
        Model::new(&Config::parse(toml).unwrap())
    }

    fn quiet() -> HoldSnapshot {
        HoldSnapshot::default()
    }

    fn video() -> HoldSnapshot {
        HoldSnapshot { inhibitors: vec!["mpv".into()], ..Default::default() }
    }

    fn music() -> HoldSnapshot {
        HoldSnapshot { audio: true, ..Default::default() }
    }

    fn reach(m: &mut Model, now: u64, station: Station, holds: HoldSnapshot) -> Vec<Effect> {
        let locked = m.locked();
        m.step(now, Event::Reached { station, holds, locked })
    }

    #[test]
    fn saver_then_dark_locks_with_the_dark_and_wakes_on_input() {
        let mut m = model("");
        assert_eq!(reach(&mut m, 900, Station::Saver, quiet()), [StartSaver]);
        assert_eq!(m.lamp().class, "saver");
        assert_eq!(reach(&mut m, 3600, Station::Dark, quiet()), [Lock, StopSaver, ScreensOff]);
        assert_eq!(m.lamp().class, "dark");
        assert_eq!(m.step(3700, Event::Resumed), [ScreensOn]);
        assert_eq!(m.phase(), Phase::Active);
    }

    #[test]
    fn input_during_the_saver_stops_it() {
        let mut m = model("");
        reach(&mut m, 900, Station::Saver, quiet());
        assert_eq!(m.step(950, Event::Resumed), [StopSaver]);
    }

    #[test]
    fn a_video_holds_the_saver_until_it_stops() {
        let mut m = model("");
        assert_eq!(reach(&mut m, 900, Station::Saver, video()), [Retry { after: 60 }]);
        let lamp = m.lamp();
        assert_eq!(lamp.class, "held");
        assert!(lamp.tooltip.contains("mpv is keeping the screen on"), "{}", lamp.tooltip);
        assert_eq!(
            m.step(960, Event::Retry { holds: video(), locked: false }),
            [Retry { after: 60 }]
        );
        assert_eq!(m.step(1020, Event::Retry { holds: quiet(), locked: false }), [StartSaver]);
    }

    #[test]
    fn audio_holds_the_dark_but_not_the_saver() {
        let mut m = model("");
        assert_eq!(reach(&mut m, 900, Station::Saver, music()), [StartSaver]);
        assert_eq!(reach(&mut m, 3600, Station::Dark, music()), [Retry { after: 60 }]);
        assert_eq!(m.phase(), Phase::Saver, "the saver keeps running while held");
        assert_eq!(
            m.step(3660, Event::Retry { holds: quiet(), locked: false }),
            [Lock, StopSaver, ScreensOff]
        );
    }

    #[test]
    fn audio_all_holds_the_saver_too() {
        let mut m = model("[holds]\naudio = \"all\"");
        assert_eq!(reach(&mut m, 900, Station::Saver, music()), [Retry { after: 60 }]);
    }

    #[test]
    fn when_saver_and_dark_were_both_held_the_dark_wins() {
        let mut m = model("");
        reach(&mut m, 900, Station::Saver, video());
        reach(&mut m, 3600, Station::Dark, video());
        assert_eq!(
            m.step(3660, Event::Retry { holds: quiet(), locked: false }),
            [Lock, ScreensOff]
        );
    }

    #[test]
    fn a_hand_lock_goes_dark_after_a_minute() {
        let mut m = model("");
        assert_eq!(
            m.step(
                60,
                Event::Reached { station: Station::LockedDark, holds: quiet(), locked: true }
            ),
            [ScreensOff]
        );
    }

    #[test]
    fn the_short_timeout_does_nothing_without_a_lock() {
        let mut m = model("");
        assert!(reach(&mut m, 60, Station::LockedDark, quiet()).is_empty());
    }

    #[test]
    fn a_timed_lock_stops_the_saver_and_goes_dark_a_minute_later() {
        let mut m = model("[line]\nlock = \"20m\"");
        reach(&mut m, 900, Station::Saver, quiet());
        assert_eq!(reach(&mut m, 1200, Station::Lock, quiet()), [Lock, StopSaver]);
        assert!(m.step(1230, Event::Tick).is_empty());
        assert_eq!(m.step(1260, Event::Tick), [Retry { after: 0 }]);
        assert_eq!(m.step(1260, Event::Retry { holds: quiet(), locked: true }), [ScreensOff]);
    }

    #[test]
    fn no_saver_over_a_lock_screen() {
        let mut m = model("");
        assert!(
            m.step(900, Event::Reached { station: Station::Saver, holds: quiet(), locked: true })
                .is_empty()
        );
    }

    #[test]
    fn a_manual_hold_holds_everything_until_it_runs_out() {
        let mut m = model("");
        m.step(0, Event::Hold { secs: 3600 });
        assert_eq!(m.lamp().class, "held");
        assert!(m.lamp().tooltip.contains("1h more"), "{}", m.lamp().tooltip);
        assert_eq!(reach(&mut m, 900, Station::Saver, quiet()), [Retry { after: 60 }]);
        assert_eq!(m.step(3600, Event::Tick), [Retry { after: 0 }]);
        assert_eq!(m.step(3600, Event::Retry { holds: quiet(), locked: false }), [StartSaver]);
    }

    #[test]
    fn release_retries_right_away() {
        let mut m = model("");
        m.step(0, Event::Hold { secs: 3600 });
        reach(&mut m, 900, Station::Saver, quiet());
        assert_eq!(m.step(950, Event::Release), [Retry { after: 0 }]);
    }

    #[test]
    fn now_starts_the_saver_and_its_exit_ends_it() {
        let mut m = model("");
        assert_eq!(m.step(5, Event::Now), [StartSaver]);
        assert!(m.step(9, Event::SaverExited).is_empty());
        assert_eq!(m.phase(), Phase::Active);
    }

    #[test]
    fn lock_off_never_locks() {
        let mut m = model("[line]\nlock = \"off\"");
        assert_eq!(reach(&mut m, 3600, Station::Dark, quiet()), [ScreensOff]);
    }

    #[test]
    fn inhibitors_can_be_turned_off() {
        let mut m = model("[holds]\ninhibitors = false");
        assert_eq!(reach(&mut m, 900, Station::Saver, video()), [StartSaver]);
    }

    fn whats(m: &Model) -> Vec<String> {
        m.history().map(|e| format!("{}: {}", e.what, e.why)).collect()
    }

    #[test]
    fn history_tells_the_story_once() {
        let mut m = model("");
        reach(&mut m, 900, Station::Saver, video());
        m.step(960, Event::Retry { holds: video(), locked: false });
        m.step(1020, Event::Retry { holds: video(), locked: false });
        m.step(1080, Event::Retry { holds: quiet(), locked: false });
        reach(&mut m, 3600, Station::Dark, quiet());
        m.step(3700, Event::Resumed);
        assert_eq!(
            whats(&m),
            [
                "The saver held: mpv is keeping the screen on",
                "Saver started: nothing holds it now",
                "Locked: with the dark",
                "Screens off: 1h idle",
                "Screens on: input came back",
            ]
        );
    }

    #[test]
    fn history_keeps_the_last_fifty() {
        let mut m = model("");
        for i in 0..60 {
            m.step(i, Event::Hold { secs: 60 });
        }
        assert_eq!(m.history().count(), HISTORY);
    }

    #[test]
    fn the_snapshot_is_newest_first_and_names_the_hack_only_while_it_runs() {
        let mut m = model("");
        let clock = |t: u64| format!("t{t}");
        assert_eq!(m.snapshot(&clock, Some("Starfield".into()), vec![]).hack, None);
        m.step(5, Event::Now);
        m.step(9, Event::Hold { secs: 3600 });
        let s = m.snapshot(&clock, Some("Starfield".into()), vec![]);
        assert_eq!(s.hack.as_deref(), Some("Starfield"));
        assert_eq!(s.headline, "Saver running");
        assert_eq!(s.history[0].what, "Held");
        assert_eq!(s.history[0].time, "t9");
        assert!(s.manual_hold);
        assert_eq!(s.stations.len(), 4);
    }

    #[test]
    fn a_loosened_config_shows_on_the_lamp() {
        let m = model("[line]\ndark = \"off\"");
        let lamp = m.lamp();
        assert_eq!(lamp.class, "loose");
        assert!(lamp.tooltip.contains("line.dark = off"), "{}", lamp.tooltip);
        assert_eq!(model("").lamp().class, "armed");
    }
}
