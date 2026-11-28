//! Audition: the saver stepping through every hack on the real panel while
//! you decide. Arrows step, `k` keeps a hack in the rotation or leaves it
//! out, `s` stars it, Space pauses the 20 second steps, Escape or a click
//! ends it, and two minutes without a key end it on their own. The rules
//! live here; the saver draws.

use crate::hud::Line;
use layover_core::config::Weight;
use layover_hacks::Hack;
use std::time::{Duration, Instant};

/// Each hack's turn while nobody touches a key.
pub const STEP_EVERY: Duration = Duration::from_secs(20);
/// Audition ends after this long without a key.
pub const QUIET_END: Duration = Duration::from_secs(120);
/// The strip shows this long after a key or a step, then fades.
pub const STRIP_FOR: Duration = Duration::from_secs(4);
pub const STRIP_FADE: Duration = Duration::from_secs(1);
/// A new hack fades in over this long.
pub const FADE_IN: f32 = 0.6;

/// evdev key codes: layout-independent for the keys Audition reads.
pub mod keys {
    pub const ESC: u32 = 1;
    pub const K: u32 = 37;
    pub const S: u32 = 31;
    pub const SPACE: u32 = 57;
    pub const UP: u32 = 103;
    pub const LEFT: u32 = 105;
    pub const RIGHT: u32 = 106;
    pub const DOWN: u32 = 108;
}

/// What a key asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Prev,
    Next,
    Keep,
    Star,
    Pause,
    Done,
    /// Any other key: show the strip.
    Show,
}

pub fn action(key: u32) -> Action {
    match key {
        keys::LEFT | keys::UP => Action::Prev,
        keys::RIGHT | keys::DOWN => Action::Next,
        keys::K => Action::Keep,
        keys::S => Action::Star,
        keys::SPACE => Action::Pause,
        keys::ESC => Action::Done,
        _ => Action::Show,
    }
}

pub struct Audition {
    pub hacks: Vec<&'static Hack>,
    pub weights: Vec<Weight>,
    pub at: usize,
    /// When the hack on screen came up.
    pub since: Instant,
    pub last_key: Instant,
    pub paused: bool,
    /// A change that was refused, shown on the strip until the next step.
    pub note: Option<&'static str>,
}

/// A weight change to write to the config.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub id: &'static str,
    pub weight: Weight,
}

impl Audition {
    pub fn new(hacks: Vec<&'static Hack>, weights: Vec<Weight>, now: Instant) -> Audition {
        Audition { hacks, weights, at: 0, since: now, last_key: now, paused: false, note: None }
    }

    pub fn hack(&self) -> &'static Hack {
        self.hacks[self.at]
    }

    fn step(&mut self, by: isize, now: Instant) {
        let n = self.hacks.len() as isize;
        self.at = ((self.at as isize + by).rem_euclid(n)) as usize;
        self.since = now;
        self.note = None;
    }

    /// Takes a key; returns a change to write, if it made one.
    pub fn key(&mut self, a: Action, now: Instant) -> Option<Change> {
        self.last_key = now;
        let id = self.hack().id;
        let w = self.weights[self.at];
        let to = match a {
            Action::Prev => {
                self.step(-1, now);
                return None;
            }
            Action::Next => {
                self.step(1, now);
                return None;
            }
            Action::Pause => {
                self.paused = !self.paused;
                return None;
            }
            Action::Done | Action::Show => return None,
            Action::Keep => {
                if w == Weight::Never {
                    Weight::Sometimes
                } else {
                    Weight::Never
                }
            }
            Action::Star => {
                if w == Weight::Often {
                    Weight::Sometimes
                } else {
                    Weight::Often
                }
            }
        };
        let kept = self.weights.iter().filter(|w| **w != Weight::Never).count();
        if to == Weight::Never && w != Weight::Never && kept <= 1 {
            self.note = Some("KEEP AT LEAST ONE");
            return None;
        }
        // A hack appears once in the reel; set every copy all the same.
        for (i, h) in self.hacks.iter().enumerate() {
            if h.id == id {
                self.weights[i] = to;
            }
        }
        Some(Change { id, weight: to })
    }

    /// Time passing: the 20 second step. True when Audition should end.
    pub fn tick(&mut self, now: Instant) -> bool {
        if now.duration_since(self.last_key) >= QUIET_END {
            return true;
        }
        if !self.paused && now.duration_since(self.since) >= STEP_EVERY {
            self.step(1, now);
        }
        false
    }

    /// How visible the strip is now, 0 to 1.
    pub fn strip_level(&self, now: Instant) -> f32 {
        let since = now.duration_since(self.last_key.max(self.since));
        if since <= STRIP_FOR {
            1.0
        } else {
            1.0 - ((since - STRIP_FOR).as_secs_f32() / STRIP_FADE.as_secs_f32()).min(1.0)
        }
    }

    /// The strip's lines.
    pub fn lines(&self) -> Vec<Line> {
        let h = self.hack();
        let w = self.weights[self.at];
        let n = self.hacks.len();
        let mut status = match w {
            Weight::Never => "LEFT OUT".to_string(),
            Weight::Sometimes => "IN ROTATION".to_string(),
            Weight::Often => "IN ROTATION · STARRED *".to_string(),
        };
        if self.paused {
            status.push_str(" · PAUSED");
        }
        if let Some(n) = self.note {
            status = n.to_string();
        }
        let status_color = match (self.note, w) {
            (Some(_), _) => [178, 108, 112],
            (None, Weight::Never) => [172, 100, 106],
            (None, Weight::Sometimes) => [132, 160, 112],
            (None, Weight::Often) => [178, 152, 100],
        };
        vec![
            Line {
                text: format!("< {}  {}/{n} >", h.name.to_uppercase(), self.at + 1),
                color: [168, 174, 180],
            },
            Line { text: status, color: status_color },
            Line {
                text: "<- -> STEP  K KEEP  S STAR  SPACE PAUSE  ESC DONE".into(),
                color: [105, 112, 122],
            },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reel(n: usize, now: Instant) -> Audition {
        let hacks: Vec<_> = layover_hacks::HACKS.iter().take(n).collect();
        let weights = vec![Weight::Sometimes; n];
        Audition::new(hacks, weights, now)
    }

    #[test]
    fn arrows_step_round_and_keys_set_weights() {
        let t = Instant::now();
        let mut a = reel(3, t);
        a.key(Action::Prev, t);
        assert_eq!(a.at, 2, "back wraps to the end");
        a.key(Action::Next, t);
        assert_eq!(a.at, 0);
        let id = a.hack().id;
        assert_eq!(a.key(Action::Star, t), Some(Change { id, weight: Weight::Often }));
        assert_eq!(a.key(Action::Keep, t), Some(Change { id, weight: Weight::Never }));
        assert_eq!(a.key(Action::Keep, t), Some(Change { id, weight: Weight::Sometimes }));
        assert_eq!(action(keys::ESC), Action::Done);
        assert_eq!(action(30), Action::Show);
    }

    #[test]
    fn the_last_hack_in_the_rotation_stays() {
        let t = Instant::now();
        let mut a = reel(2, t);
        assert!(a.key(Action::Keep, t).is_some());
        a.key(Action::Next, t);
        assert_eq!(a.key(Action::Keep, t), None);
        assert_eq!(a.note, Some("KEEP AT LEAST ONE"));
    }

    #[test]
    fn it_steps_every_twenty_seconds_pauses_and_ends_when_left_alone() {
        let t = Instant::now();
        let mut a = reel(3, t);
        assert!(!a.tick(t + Duration::from_secs(19)));
        assert_eq!(a.at, 0);
        a.tick(t + Duration::from_secs(20));
        assert_eq!(a.at, 1);
        a.key(Action::Pause, t + Duration::from_secs(21));
        a.tick(t + Duration::from_secs(60));
        assert_eq!(a.at, 1, "paused");
        assert!(a.tick(t + Duration::from_secs(21) + QUIET_END));
    }

    #[test]
    fn the_strip_fades_after_a_few_seconds() {
        let t = Instant::now();
        let a = reel(3, t);
        assert_eq!(a.strip_level(t + Duration::from_secs(2)), 1.0);
        assert!(a.strip_level(t + STRIP_FOR + STRIP_FADE / 2) < 1.0);
        assert_eq!(a.strip_level(t + STRIP_FOR + STRIP_FADE), 0.0);
        assert!(a.lines()[0].text.contains("1/3"));
    }
}
