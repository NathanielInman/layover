//! Durations as people write them in the config: `"20s"`, `"15m"`, `"1h"`,
//! `"1h30m"`, and `"off"` where a setting may be turned off.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use std::time::Duration;

/// Parse `"1h30m"`, `"15m"`, `"90s"`. Units are `h`, `m` and `s`; a bare
/// number is not accepted, so `"15"` never silently means seconds.
pub fn parse_duration(text: &str) -> Result<Duration, String> {
    let s = text.trim();
    if s.is_empty() {
        return Err("empty duration".into());
    }
    let mut total = 0u64;
    let mut num = String::new();
    let mut saw_unit = false;
    for ch in s.chars() {
        if ch.is_ascii_digit() {
            num.push(ch);
            continue;
        }
        let mult = match ch {
            'h' => 3600,
            'm' => 60,
            's' => 1,
            _ => return Err(format!("`{text}`: unknown unit `{ch}` (use h, m or s)")),
        };
        if num.is_empty() {
            return Err(format!("`{text}`: `{ch}` needs a number before it"));
        }
        let n: u64 = num.parse().map_err(|_| format!("`{text}`: number too large"))?;
        total = total
            .checked_add(n.saturating_mul(mult))
            .ok_or_else(|| format!("`{text}`: too long"))?;
        num.clear();
        saw_unit = true;
    }
    if !num.is_empty() {
        return Err(format!("`{text}`: give the number a unit, like `{num}m`"));
    }
    if !saw_unit {
        return Err(format!("`{text}`: not a duration"));
    }
    Ok(Duration::from_secs(total))
}

/// Write a duration the way the config spells it: `"1h30m"`, `"15m"`, `"20s"`.
pub fn format_duration(d: Duration) -> String {
    let mut secs = d.as_secs();
    if secs == 0 {
        return "0s".into();
    }
    let mut out = String::new();
    for (unit, size) in [('h', 3600), ('m', 60), ('s', 1)] {
        if secs >= size {
            out.push_str(&format!("{}{unit}", secs / size));
            secs %= size;
        }
    }
    out
}

/// A duration, or `"off"`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Span {
    After(Duration),
    Off,
}

impl Span {
    pub fn mins(m: u64) -> Self {
        Span::After(Duration::from_secs(m * 60))
    }
    pub fn secs(s: u64) -> Self {
        Span::After(Duration::from_secs(s))
    }
    pub fn duration(self) -> Option<Duration> {
        match self {
            Span::After(d) => Some(d),
            Span::Off => None,
        }
    }
    /// True when `self` is looser than `shipped`: off where the shipped value
    /// is on, or longer. (`Off` sorts after every duration.)
    pub fn looser_than(self, shipped: Span) -> bool {
        self > shipped
    }
}

impl fmt::Display for Span {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Span::After(d) => f.write_str(&format_duration(*d)),
            Span::Off => f.write_str("off"),
        }
    }
}

impl<'de> Deserialize<'de> for Span {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        let s = String::deserialize(de)?;
        if s.trim().eq_ignore_ascii_case("off") {
            return Ok(Span::Off);
        }
        parse_duration(&s).map(Span::After).map_err(serde::de::Error::custom)
    }
}

impl Serialize for Span {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        ser.serialize_str(&self.to_string())
    }
}

/// A duration that cannot be turned off.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Dur(pub Duration);

impl Dur {
    pub fn secs(s: u64) -> Self {
        Dur(Duration::from_secs(s))
    }
    pub fn mins(m: u64) -> Self {
        Dur(Duration::from_secs(m * 60))
    }
}

impl fmt::Display for Dur {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&format_duration(self.0))
    }
}

impl<'de> Deserialize<'de> for Dur {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        let s = String::deserialize(de)?;
        parse_duration(&s).map(Dur).map_err(serde::de::Error::custom)
    }
}

impl Serialize for Dur {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        ser.serialize_str(&self.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_units_and_combinations() {
        assert_eq!(parse_duration("20s").unwrap(), Duration::from_secs(20));
        assert_eq!(parse_duration("15m").unwrap(), Duration::from_secs(900));
        assert_eq!(parse_duration("1h").unwrap(), Duration::from_secs(3600));
        assert_eq!(parse_duration("1h30m").unwrap(), Duration::from_secs(5400));
        assert_eq!(parse_duration(" 2m5s ").unwrap(), Duration::from_secs(125));
    }

    #[test]
    fn refuses_bare_numbers_and_unknown_units() {
        assert!(parse_duration("15").is_err());
        assert!(parse_duration("15d").is_err());
        assert!(parse_duration("m").is_err());
        assert!(parse_duration("").is_err());
    }

    #[test]
    fn formats_back() {
        assert_eq!(format_duration(Duration::from_secs(5400)), "1h30m");
        assert_eq!(format_duration(Duration::from_secs(900)), "15m");
        assert_eq!(format_duration(Duration::from_secs(20)), "20s");
    }

    #[test]
    fn off_is_looser_than_any_duration() {
        assert!(Span::Off.looser_than(Span::mins(60)));
        assert!(Span::mins(90).looser_than(Span::mins(60)));
        assert!(!Span::mins(30).looser_than(Span::mins(60)));
        assert!(!Span::mins(60).looser_than(Span::mins(60)));
    }
}
