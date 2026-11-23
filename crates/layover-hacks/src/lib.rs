//! Layover's hacks and the renderer that draws them under rule one.

pub mod board;
pub mod gpu;
pub mod renderer;
pub mod wear;

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
    /// Reads the Departure Board's cells (the board binding).
    pub board: bool,
    /// Uses the Tier R raymarch helpers (`rm_march`, `rm_normal`, `rm_ao`, `rm_shadow`).
    pub raymarch: bool,
    pub source: &'static str,
}

pub const HACKS: &[Hack] = &[
    Hack {
        id: "night-mail",
        name: "Night Mail",
        about: "A mail train crosses dark hills while the moon climbs across the sky.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/night-mail.wgsl"),
    },
    Hack {
        id: "frost-aurora",
        name: "Frost Aurora",
        about: "Frost, green and purple curtains over black mountains.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/frost-aurora.wgsl"),
    },
    Hack {
        id: "signal-lamps",
        name: "Signal Lamps",
        about: "Out-of-focus yard lamps drifting in the dark, a few of them blinking.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/signal-lamps.wgsl"),
    },
    Hack {
        id: "starfield",
        name: "Starfield",
        about: "The classic flight through the stars, rebuilt for 32:9.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/starfield.wgsl"),
    },
    Hack {
        id: "menger-vault",
        name: "Menger Vault",
        about: "An endless vaulted Menger sponge curving through the dark (after Menger by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: true,
        source: include_str!("hacks/menger-vault.wgsl"),
    },
    Hack {
        id: "quasi-lattice",
        name: "Quasi Lattice",
        about: "Shifting aperiodic crystal tilings from interfering plane waves (after Quasicrystal by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/quasi-lattice.wgsl"),
    },
    Hack {
        id: "ripple-tank",
        name: "Ripple Tank",
        about: "Rings from drifting sources cross into shifting interference bands (after Interference by Hannu Mallat).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/ripple-tank.wgsl"),
    },
    Hack {
        id: "moire-loom",
        name: "Moire Loom",
        about: "Overlapping optical rulings weave shifting watered-silk interference bands (after Moire and Moire2 by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        source: include_str!("hacks/moire-loom.wgsl"),
    },
    Hack {
        id: "departure-board",
        name: "Departure Board",
        about: "Split-flap rows from the other tools on the desk: states and counts, never titles.",
        text_heavy: true,
        hue_turn: false,
        board: true,
        raymarch: false,
        source: include_str!("hacks/departure-board.wgsl"),
    },
];

pub fn find(id: &str) -> Option<&'static Hack> {
    HACKS.iter().find(|h| h.id == id)
}

/// Seconds of fade through black between hacks, and in at the start.
pub const FADE: f32 = 1.5;

/// The hack on screen `elapsed` seconds into a run, and how far it has
/// faded in (0 to 1). Hacks take turns for `care.rotate` each, text-heavy
/// ones for `care.text_rotate` (rule four).
pub fn showing(
    hacks: &[&'static Hack],
    care: &layover_core::config::Care,
    elapsed: f32,
) -> (&'static Hack, f32) {
    let spans: Vec<f32> = hacks
        .iter()
        .map(|h| {
            if h.text_heavy { care.text_rotate.0 } else { care.rotate.0 }.as_secs_f32().max(30.0)
        })
        .collect();
    let cycle: f32 = spans.iter().sum();
    let mut at = elapsed % cycle.max(1.0);
    for (hack, span) in hacks.iter().zip(&spans) {
        if at < *span {
            let fade_in = (at / FADE).min(1.0);
            let fade_out = ((span - at) / FADE).min(1.0);
            let start = (elapsed / FADE).min(1.0);
            let fade = if hacks.len() > 1 { fade_in.min(fade_out) } else { 1.0 };
            return (hack, fade.min(start));
        }
        at -= span;
    }
    (hacks[0], 1.0)
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
    fn hacks_take_turns_and_fade_through_black() {
        let care = layover_core::config::Care::default();
        let all = rotation(&[]).unwrap();
        let before_board = all.iter().take_while(|h| !h.text_heavy).count() as f32;
        assert_eq!(showing(&all, &care, 0.0).1, 0.0, "a run fades in");
        let (h, fade) = showing(&all, &care, 60.0);
        assert_eq!((h.id, fade), (all[0].id, 1.0));
        assert_eq!(showing(&all, &care, 601.0).0.id, all[1].id, "the second hack after 10m");
        assert!(showing(&all, &care, 599.5).1 < 1.0, "fading out before the hand-off");
        assert_eq!(
            showing(&all, &care, before_board * 600.0 + 60.0).0.id,
            "departure-board",
            "the text-heavy board after the non-text hacks"
        );
        assert_eq!(
            showing(&all, &care, before_board * 600.0 + 180.0 + 60.0).0.id,
            all[0].id,
            "and round again after the board's 3m (care.text_rotate)"
        );
    }

    #[test]
    fn rotation_defaults_to_every_hack_and_names_unknown_ones() {
        assert_eq!(rotation(&[]).unwrap().len(), HACKS.len());
        assert_eq!(rotation(&["starfield".into()]).unwrap()[0].id, "starfield");
        assert!(rotation(&["nope".into()]).unwrap_err().contains("nope"));
    }
}
