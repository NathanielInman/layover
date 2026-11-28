//! The lamp: what waybar shows, one JSON object per line.

use serde::{Deserialize, Serialize};

/// The lamp's glyph: Nerd Font md-weather-night. Waybar hides a module whose
/// text is empty, so every state but `off` prints it; the class colors it.
pub const MOON: &str = "\u{f0594}";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lamp {
    pub text: String,
    pub alt: String,
    pub class: String,
    pub tooltip: String,
}

impl Lamp {
    pub fn new(class: &str, tooltip: String) -> Lamp {
        let text = if class == "off" { String::new() } else { MOON.to_string() };
        Lamp { text, alt: class.into(), class: class.into(), tooltip }
    }

    /// A lamp whose text carries a short count beside the moon ("2m"),
    /// for the minutes before the saver or left on a hold.
    pub fn with_count(class: &str, tooltip: String, count: Option<String>) -> Lamp {
        let mut l = Lamp::new(class, tooltip);
        if let Some(c) = count.filter(|_| class != "off") {
            l.text = format!("{MOON} {c}");
        }
        l
    }

    /// The lamp when no daemon answers.
    pub fn off() -> Lamp {
        Lamp::new("off", "Layover is not running. `layover daemon` starts it.".into())
    }

    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("a lamp is plain strings")
    }
}
