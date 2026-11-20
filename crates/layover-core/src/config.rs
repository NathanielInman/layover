//! `layover.toml`: the shipped defaults, validation, and the check that lists
//! every value looser than shipped (rule six in `docs/design.md`).
//!
//! `packaging/examples/config.toml` is the shipped file with every key, its
//! reason and its warning. A test below fails when it and [`Config::default`]
//! disagree.

use crate::span::{Dur, Span};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::path::Path;
use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, Default)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub line: Line,
    pub holds: Holds,
    pub feeds: Feeds,
    pub care: Care,
    pub power: Power,
    pub saver: Saver,
    pub bar: Bar,
    pub drawer: Drawer,
    pub theme: Theme,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Line {
    pub saver: Span,
    pub dark: Span,
    pub lock: LockAt,
    pub locked_dark: Span,
    pub lock_command: Vec<String>,
    pub dark_command: Vec<String>,
    pub wake_command: Vec<String>,
}

impl Default for Line {
    fn default() -> Self {
        Line {
            saver: Span::mins(15),
            dark: Span::mins(60),
            lock: LockAt::Dark,
            locked_dark: Span::mins(1),
            lock_command: vec!["hyprlock".into()],
            dark_command: vec![],
            wake_command: vec![],
        }
    }
}

/// When the session locks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockAt {
    /// As the screens go off.
    Dark,
    /// After this much idle.
    After(Duration),
    Off,
}

impl std::fmt::Display for LockAt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockAt::Dark => f.write_str("dark"),
            LockAt::Off => f.write_str("off"),
            LockAt::After(d) => f.write_str(&crate::span::format_duration(*d)),
        }
    }
}

impl<'de> Deserialize<'de> for LockAt {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        let s = String::deserialize(de)?;
        match s.trim().to_ascii_lowercase().as_str() {
            "dark" => Ok(LockAt::Dark),
            "off" => Ok(LockAt::Off),
            _ => {
                crate::span::parse_duration(&s).map(LockAt::After).map_err(serde::de::Error::custom)
            }
        }
    }
}

impl Serialize for LockAt {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        ser.serialize_str(&self.to_string())
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Holds {
    pub inhibitors: bool,
    pub ignore: Vec<String>,
    pub mic: bool,
    pub audio: AudioHold,
}

impl Default for Holds {
    fn default() -> Self {
        Holds {
            inhibitors: true,
            ignore: vec!["com.t3tools.T3Code".into()],
            mic: true,
            audio: AudioHold::Dark,
        }
    }
}

/// The other tools on the desk, read from their waybar lamps ("The line"
/// in `docs/design.md`). Each is the command that prints its lamp; an empty
/// list turns it off, and a command that isn't installed is skipped.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Feeds {
    pub timetable: Vec<String>,
    pub switchyard: Vec<String>,
    pub waybill: Vec<String>,
    pub signal_box: Vec<String>,
    pub roundhouse: Vec<String>,
    pub tablet: Vec<String>,
    pub logbook: Vec<String>,
    pub tannoy: Vec<String>,
    /// Logbook on air holds the saver, the lock and the dark.
    pub hold_on_air: bool,
    /// A meeting soon (Timetable) holds the saver.
    pub hold_meeting: bool,
    /// A heavy build (Switchyard) or a hot machine (Roundhouse) puts the
    /// saver in cheap mode.
    pub cheap: bool,
}

impl Default for Feeds {
    fn default() -> Self {
        let cmd = |p: &str| vec![p.to_string(), "bar".to_string()];
        Feeds {
            timetable: cmd("timetable"),
            switchyard: cmd("yard"),
            waybill: cmd("waybill"),
            signal_box: cmd("broker"),
            roundhouse: cmd("rh"),
            tablet: cmd("tablet"),
            logbook: cmd("logbook"),
            tannoy: cmd("tannoy"),
            hold_on_air: true,
            hold_meeting: true,
            cheap: true,
        }
    }
}

impl Feeds {
    pub fn command(&self, feed: crate::feeds::Feed) -> &[String] {
        use crate::feeds::Feed::*;
        match feed {
            Timetable => &self.timetable,
            Switchyard => &self.switchyard,
            Waybill => &self.waybill,
            SignalBox => &self.signal_box,
            Roundhouse => &self.roundhouse,
            Tablet => &self.tablet,
            Logbook => &self.logbook,
            Tannoy => &self.tannoy,
        }
    }
}

/// What playing audio holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioHold {
    /// Only the dark: the saver still runs while music plays.
    Dark,
    /// The saver, the lock and the dark.
    All,
    Off,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Care {
    pub max_drive: f32,
    pub max_average: f32,
    pub max_dwell: Dur,
    pub orbit: Span,
    pub hue_cycle: Span,
    pub max_white: f32,
    pub rotate: Dur,
    pub text_rotate: Dur,
    pub max_hot_spot: f32,
}

impl Default for Care {
    fn default() -> Self {
        Care {
            max_drive: 0.60,
            max_average: 0.12,
            max_dwell: Dur::secs(20),
            orbit: Span::mins(4),
            hue_cycle: Span::mins(6),
            max_white: 0.35,
            rotate: Dur::mins(10),
            text_rotate: Dur::mins(3),
            max_hot_spot: 0.25,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Power {
    pub mode: PowerMode,
    pub fps: u32,
    pub render_scale: f32,
    pub gpu: Gpu,
}

impl Default for Power {
    fn default() -> Self {
        Power { mode: PowerMode::Save, fps: 30, render_scale: 0.5, gpu: Gpu::Auto }
    }
}

impl Power {
    /// The frame rate the saver uses: `fps`, or 60 with power saving off.
    pub fn effective_fps(&self) -> u32 {
        match self.mode {
            PowerMode::Save => self.fps,
            PowerMode::Off => 60,
        }
    }
    /// The render scale the saver uses: `render_scale`, or 1 with power saving off.
    pub fn effective_scale(&self) -> f32 {
        match self.mode {
            PowerMode::Save => self.render_scale,
            PowerMode::Off => 1.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PowerMode {
    Save,
    Off,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Gpu {
    /// The adapter that drives the screens.
    Auto,
    LowPower,
    HighPerformance,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, Default)]
#[serde(default, deny_unknown_fields)]
pub struct Saver {
    /// Hacks in the rotation, by id. Empty means every hack, in order.
    pub hacks: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Bar {
    /// The layer-shell namespace of the bar surface, used to find its edge
    /// when the drawer opens from the clicked icon.
    pub namespace: String,
}

impl Default for Bar {
    fn default() -> Self {
        Bar { namespace: "waybar".into() }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Drawer {
    /// Panel width in logical pixels.
    pub width: f64,
    /// The tallest the panel gets, as a share of the monitor's height.
    pub max_height: f64,
    /// Space between the bar and the panel.
    pub gap: f64,
}

impl Default for Drawer {
    fn default() -> Self {
        Drawer { width: 420.0, max_height: 0.85, gap: 8.0 }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Theme {
    /// `waybar` takes the font and colors from the bar's style.css; `none`
    /// keeps the built-in look.
    pub from: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font: Option<String>,
}

impl Default for Theme {
    fn default() -> Self {
        Theme { from: "waybar".into(), accent: None, font: None }
    }
}

/// What a loosened value puts at risk.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Concern {
    /// Burn-in and wear on the monitor.
    Panel,
    /// Energy and GPU heat.
    Power,
}

/// One value looser than shipped.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Loosened {
    pub key: &'static str,
    pub value: String,
    pub shipped: String,
    pub concern: Concern,
    pub why: &'static str,
}

impl std::fmt::Display for Loosened {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} = {} (shipped {}): {}", self.key, self.value, self.shipped, self.why)
    }
}

const ONE_MINUTE: Duration = Duration::from_secs(60);

impl Config {
    /// Read the config at `path`. A missing file means the shipped defaults.
    pub fn load(path: &Path) -> Result<Config> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Config::default()),
            Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
        };
        Config::parse(&text).with_context(|| format!("in {}", path.display()))
    }

    pub fn parse(text: &str) -> Result<Config> {
        let cfg: Config = toml::from_str(text)?;
        cfg.validate()?;
        Ok(cfg)
    }

    /// Refuse values Layover cannot run with. Values that are merely risky
    /// pass here and show up in [`Config::loosened`].
    pub fn validate(&self) -> Result<()> {
        let l = &self.line;
        for (key, span) in [("line.saver", l.saver), ("line.dark", l.dark)] {
            if let Span::After(d) = span
                && d < ONE_MINUTE
            {
                bail!("{key} is {span}; the shortest is 1m (or \"off\")");
            }
        }
        if let LockAt::After(d) = l.lock
            && d < ONE_MINUTE
        {
            bail!("line.lock is {}; the shortest is 1m", l.lock);
        }
        if let Span::After(d) = l.locked_dark
            && d < Duration::from_secs(10)
        {
            bail!("line.locked_dark is {}; the shortest is 10s", l.locked_dark);
        }
        if l.lock != LockAt::Off && l.lock_command.is_empty() {
            bail!("line.lock_command is empty; set a lock command or line.lock = \"off\"");
        }
        let c = &self.care;
        for (key, v) in [
            ("care.max_drive", c.max_drive),
            ("care.max_average", c.max_average),
            ("care.max_white", c.max_white),
            ("care.max_hot_spot", c.max_hot_spot),
        ] {
            if !(v > 0.0 && v <= 1.0) {
                bail!("{key} is {v}; it must be above 0 and at most 1");
            }
        }
        if let Span::After(d) = c.orbit
            && d < Duration::from_secs(30)
        {
            bail!("care.orbit is {}; the shortest cycle is 30s", c.orbit);
        }
        if let Span::After(d) = c.hue_cycle
            && d < ONE_MINUTE
        {
            bail!("care.hue_cycle is {}; the shortest cycle is 1m", c.hue_cycle);
        }
        for (key, d) in [("care.rotate", c.rotate), ("care.text_rotate", c.text_rotate)] {
            if d.0 < Duration::from_secs(30) {
                bail!("{key} is {d}; the shortest is 30s");
            }
        }
        if c.max_dwell.0 < Duration::from_secs(1) {
            bail!("care.max_dwell is {}; the shortest is 1s", c.max_dwell);
        }
        let p = &self.power;
        if !(1..=240).contains(&p.fps) {
            bail!("power.fps is {}; it must be between 1 and 240", p.fps);
        }
        if !(p.render_scale >= 0.1 && p.render_scale <= 1.0) {
            bail!("power.render_scale is {}; it must be between 0.1 and 1", p.render_scale);
        }
        let d = &self.drawer;
        if !(240.0..=1600.0).contains(&d.width) {
            bail!("drawer.width is {}; it must be between 240 and 1600", d.width);
        }
        if !(d.max_height > 0.2 && d.max_height <= 1.0) {
            bail!("drawer.max_height is {}; it must be above 0.2 and at most 1", d.max_height);
        }
        if !(0.0..=64.0).contains(&d.gap) {
            bail!("drawer.gap is {}; it must be between 0 and 64", d.gap);
        }
        if !matches!(self.theme.from.as_str(), "waybar" | "none") {
            bail!("theme.from is \"{}\"; use \"waybar\" or \"none\"", self.theme.from);
        }
        Ok(())
    }

    /// Every value looser than shipped, with what it puts at risk.
    pub fn loosened(&self) -> Vec<Loosened> {
        let d = Config::default();
        let mut out = Vec::new();
        let mut span = |key, v: Span, s: Span, off_why, longer_why| {
            if v.looser_than(s) {
                out.push(Loosened {
                    key,
                    value: v.to_string(),
                    shipped: s.to_string(),
                    concern: Concern::Panel,
                    why: if v == Span::Off { off_why } else { longer_why },
                });
            }
        };
        span(
            "line.saver",
            self.line.saver,
            d.line.saver,
            "No saver: the desktop sits still on the panel until the screens go off.",
            "The desktop sits still on the panel for longer before the saver starts.",
        );
        span(
            "line.dark",
            self.line.dark,
            d.line.dark,
            "The screens never turn off. A hack runs all night, the panel never rests, and it never gets the standby time OLEDs use for pixel refresh.",
            "The saver runs longer before the panel rests.",
        );
        span(
            "line.locked_dark",
            self.line.locked_dark,
            d.line.locked_dark,
            "A still lock screen stays on the panel until you come back.",
            "A still lock screen stays on the panel for longer.",
        );
        span(
            "care.orbit",
            self.care.orbit,
            d.care.orbit,
            "The frame no longer drifts, so anything static in a hack burns in.",
            "The frame drifts more slowly, so static parts stay put for longer.",
        );
        span(
            "care.hue_cycle",
            self.care.hue_cycle,
            d.care.hue_cycle,
            "Colors no longer turn, so one color's subpixels can carry a hack and age first.",
            "Colors turn more slowly, so one color's subpixels carry more of the load.",
        );

        let mut more = |key, v: f32, s: f32, why| {
            if v > s + f32::EPSILON {
                out.push(Loosened {
                    key,
                    value: format!("{v}"),
                    shipped: format!("{s}"),
                    concern: Concern::Panel,
                    why,
                });
            }
        };
        more(
            "care.max_drive",
            self.care.max_drive,
            d.care.max_drive,
            "Subpixels driven brighter age faster.",
        );
        more(
            "care.max_average",
            self.care.max_average,
            d.care.max_average,
            "A brighter frame wears the whole panel faster and draws more power.",
        );
        more(
            "care.max_white",
            self.care.max_white,
            d.care.max_white,
            "White lights red, green and blue at once, the hardest load on a subpixel group.",
        );
        more(
            "care.max_hot_spot",
            self.care.max_hot_spot,
            d.care.max_hot_spot,
            "One area may wear faster than the rest of the panel.",
        );

        let mut longer = |key, v: Dur, s: Dur, why| {
            if v > s {
                out.push(Loosened {
                    key,
                    value: v.to_string(),
                    shipped: s.to_string(),
                    concern: Concern::Panel,
                    why,
                });
            }
        };
        longer(
            "care.max_dwell",
            self.care.max_dwell,
            d.care.max_dwell,
            "Pixels may stay lit and unchanged for longer.",
        );
        longer(
            "care.rotate",
            self.care.rotate,
            d.care.rotate,
            "One hack's pattern stays on the panel for longer.",
        );
        longer(
            "care.text_rotate",
            self.care.text_rotate,
            d.care.text_rotate,
            "Text, the hardest thing on a panel, stays up for longer.",
        );

        if self.holds.audio == AudioHold::All && d.holds.audio != AudioHold::All {
            out.push(Loosened {
                key: "holds.audio",
                value: "all".into(),
                shipped: "dark".into(),
                concern: Concern::Panel,
                why: "While audio plays, the desktop sits still on the panel instead of a hack.",
            });
        }

        if !self.feeds.cheap && d.feeds.cheap {
            out.push(Loosened {
                key: "feeds.cheap",
                value: "false".into(),
                shipped: "true".into(),
                concern: Concern::Power,
                why: "The saver draws at its full rate while a heavy build or a hot machine needs the GPU.",
            });
        }
        if self.power.mode == PowerMode::Off {
            out.push(Loosened {
                key: "power.mode",
                value: "off".into(),
                shipped: "save".into(),
                concern: Concern::Power,
                why: "Hacks render at full size and 60 fps for as long as the saver runs.",
            });
        } else {
            if self.power.fps > d.power.fps {
                out.push(Loosened {
                    key: "power.fps",
                    value: self.power.fps.to_string(),
                    shipped: d.power.fps.to_string(),
                    concern: Concern::Power,
                    why: "More frames cost energy and GPU heat for something nobody watches.",
                });
            }
            if self.power.render_scale > d.power.render_scale + f32::EPSILON {
                out.push(Loosened {
                    key: "power.render_scale",
                    value: format!("{}", self.power.render_scale),
                    shipped: format!("{}", d.power.render_scale),
                    concern: Concern::Power,
                    why: "Rendering more pixels costs energy and GPU heat.",
                });
            }
        }
        out
    }

    /// Settings that work but probably aren't what was meant.
    pub fn notes(&self) -> Vec<String> {
        let mut out = Vec::new();
        if let (Span::After(s), Span::After(d)) = (self.line.saver, self.line.dark)
            && s >= d
        {
            out.push(format!(
                "line.saver ({}) is not before line.dark ({}), so the saver never runs.",
                self.line.saver, self.line.dark
            ));
        }
        if let (LockAt::After(l), Span::After(d)) = (self.line.lock, self.line.dark)
            && l >= d
        {
            out.push(format!(
                "line.lock ({}) is not before line.dark ({}); the session locks when the screens go off.",
                self.line.lock, self.line.dark
            ));
        }
        if self.line.lock == LockAt::Dark && self.line.dark == Span::Off {
            out.push(
                "line.lock is \"dark\" but line.dark is off, so the session never locks.".into(),
            );
        }
        out
    }

    /// One line for the lamp's tooltip: what happens when.
    pub fn summary(&self) -> String {
        let saver = match self.line.saver {
            Span::After(_) => format!("saver after {}", self.line.saver),
            Span::Off => "no saver".into(),
        };
        let lock = match self.line.lock {
            LockAt::Dark => "lock with the dark".to_string(),
            LockAt::After(_) => format!("lock after {}", self.line.lock),
            LockAt::Off => "no lock".into(),
        };
        let dark = match self.line.dark {
            Span::After(_) => format!("screens off after {}", self.line.dark),
            Span::Off => "screens never turn off".into(),
        };
        let mut s = format!("{saver} · {lock} · {dark}");
        if let Some(first) = s.get_mut(0..1) {
            first.make_ascii_uppercase();
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHIPPED: &str = include_str!("../../../packaging/examples/config.toml");

    #[test]
    fn shipped_example_is_the_defaults() {
        let cfg = Config::parse(SHIPPED).expect("shipped example parses");
        assert_eq!(cfg, Config::default());
        assert!(cfg.loosened().is_empty());
        assert!(cfg.notes().is_empty());
    }

    #[test]
    fn empty_file_is_the_defaults() {
        assert_eq!(Config::parse("").unwrap(), Config::default());
    }

    #[test]
    fn shipped_example_names_every_key() {
        let shipped: toml::Table = toml::from_str(SHIPPED).unwrap();
        let defaults: toml::Table =
            toml::from_str(&toml::to_string(&Config::default()).unwrap()).unwrap();
        for (section, keys) in &defaults {
            let keys = keys.as_table().unwrap();
            let have = shipped
                .get(section)
                .and_then(|t| t.as_table())
                .unwrap_or_else(|| panic!("example is missing [{section}]"));
            for key in keys.keys() {
                assert!(have.contains_key(key), "example is missing {section}.{key}");
            }
        }
    }

    #[test]
    fn refuses_timings_under_a_minute() {
        assert!(Config::parse("[line]\nsaver = \"30s\"").is_err());
        assert!(Config::parse("[line]\ndark = \"59s\"").is_err());
        assert!(Config::parse("[line]\nsaver = \"1m\"\ndark = \"1m\"").is_ok());
    }

    #[test]
    fn allows_turning_everything_off_but_lists_it() {
        let cfg = Config::parse(
            "[line]\nsaver = \"off\"\ndark = \"off\"\n[care]\norbit = \"off\"\nhue_cycle = \"off\"\n[power]\nmode = \"off\"",
        )
        .unwrap();
        let keys: Vec<_> = cfg.loosened().iter().map(|l| l.key).collect();
        assert_eq!(keys, ["line.saver", "line.dark", "care.orbit", "care.hue_cycle", "power.mode"]);
        assert!(
            cfg.loosened().iter().find(|l| l.key == "line.dark").unwrap().why.contains("never")
        );
    }

    #[test]
    fn raising_a_care_limit_is_loosening_and_lowering_is_not() {
        let cfg = Config::parse("[care]\nmax_drive = 0.8\nmax_average = 0.05").unwrap();
        let l = cfg.loosened();
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].key, "care.max_drive");
        assert_eq!(l[0].concern, Concern::Panel);
    }

    #[test]
    fn shorter_timings_are_not_loosening() {
        let cfg = Config::parse("[line]\nsaver = \"1m\"\ndark = \"1m\"").unwrap();
        assert!(cfg.loosened().is_empty());
        assert_eq!(cfg.notes().len(), 1, "saver equal to dark never runs");
    }

    #[test]
    fn refuses_out_of_range_values() {
        assert!(Config::parse("[care]\nmax_drive = 0").is_err());
        assert!(Config::parse("[care]\nmax_drive = 1.5").is_err());
        assert!(Config::parse("[power]\nfps = 0").is_err());
        assert!(Config::parse("[power]\nrender_scale = 2.0").is_err());
        assert!(Config::parse("[line]\nlock_command = []").is_err());
        assert!(Config::parse("[line]\nlock = \"off\"\nlock_command = []").is_ok());
        assert!(Config::parse("[care]\nunknown = 1").is_err());
    }

    #[test]
    fn summary_reads_as_a_sentence() {
        assert_eq!(
            Config::default().summary(),
            "Saver after 15m · lock with the dark · screens off after 1h"
        );
    }
}
