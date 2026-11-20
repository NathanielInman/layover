//! Layover's hacks and the renderer that draws them under rule one.

pub mod gpu;
pub mod renderer;

/// A hack: a WGSL `hack(p, t)` function and what the renderer needs to know
/// about it.
#[derive(Debug)]
pub struct Hack {
    pub id: &'static str,
    pub name: &'static str,
    /// One line for `layover hacks`.
    pub about: &'static str,
    /// Text-heavy hacks hand off after `care.text_rotate`.
    pub text_heavy: bool,
    /// Whether the care pass turns its hue. A hack whose colors carry
    /// meaning turns its own neutral colors instead.
    pub hue_turn: bool,
    pub source: &'static str,
}

pub const HACKS: &[Hack] = &[
    Hack {
        id: "night-mail",
        name: "Night Mail",
        about: "A mail train crosses dark hills while the moon climbs across the sky.",
        text_heavy: false,
        hue_turn: true,
        source: include_str!("hacks/night-mail.wgsl"),
    },
    Hack {
        id: "frost-aurora",
        name: "Frost Aurora",
        about: "Frost, green and purple curtains over black mountains.",
        text_heavy: false,
        hue_turn: true,
        source: include_str!("hacks/frost-aurora.wgsl"),
    },
    Hack {
        id: "signal-lamps",
        name: "Signal Lamps",
        about: "Out-of-focus yard lamps drifting in the dark, a few of them blinking.",
        text_heavy: false,
        hue_turn: true,
        source: include_str!("hacks/signal-lamps.wgsl"),
    },
    Hack {
        id: "starfield",
        name: "Starfield",
        about: "The classic flight through the stars, rebuilt for 32:9.",
        text_heavy: false,
        hue_turn: true,
        source: include_str!("hacks/starfield.wgsl"),
    },
];

pub fn find(id: &str) -> Option<&'static Hack> {
    HACKS.iter().find(|h| h.id == id)
}

/// The rotation for a `[saver] hacks` list: every hack when empty. Unknown
/// ids come back as errors so the config check can name them.
pub fn rotation(ids: &[String]) -> Result<Vec<&'static Hack>, String> {
    if ids.is_empty() {
        return Ok(HACKS.iter().collect());
    }
    ids.iter()
        .map(|id| {
            find(id).ok_or_else(|| format!("no hack called `{id}` (`layover hacks` lists them)"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_kebab_case() {
        for (i, h) in HACKS.iter().enumerate() {
            assert!(h.id.chars().all(|c| c.is_ascii_lowercase() || c == '-'), "{}", h.id);
            assert!(HACKS[i + 1..].iter().all(|o| o.id != h.id), "duplicate {}", h.id);
        }
    }

    #[test]
    fn rotation_defaults_to_every_hack_and_names_unknown_ones() {
        assert_eq!(rotation(&[]).unwrap().len(), HACKS.len());
        assert_eq!(rotation(&["starfield".into()]).unwrap()[0].id, "starfield");
        assert!(rotation(&["nope".into()]).unwrap_err().contains("nope"));
    }
}
