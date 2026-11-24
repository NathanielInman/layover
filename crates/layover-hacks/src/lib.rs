//! Layover's hacks and the renderer that draws them under rule one.

pub mod board;
pub mod gpu;
pub mod renderer;
pub mod wear;

/// Configuration for a Tier S stateful hack (ping-pong `rgba16f` feedback).
#[derive(Clone, Copy, Debug)]
pub struct Feedback {
    /// Exponential fade time constant in seconds (`g.fade = exp(-step_dt / fade_secs)`).
    /// History decays at the same real-time rate at any frame rate (60/30/15/1 fps).
    /// `0.0` disables decay (`g.fade = 1.0`), used only in negative wear tests.
    pub fade_secs: f32,
    /// Target simulation steps per second (e.g. 60.0 for PDEs, 1.0 for 1-step trails).
    pub step_hz: f32,
    /// Hard cap on substeps per `draw_canvas` call (keeps 1 fps wear tests fast on lavapipe).
    pub max_steps: u32,
    /// Optional cap on state texture height in pixels (`None` uses the full offscreen size).
    pub max_height: Option<u32>,
    /// Whether `state_tex` wraps toroidally (`Repeat`) or clamps (`ClampToEdge`).
    pub wrap: bool,
}

/// Configuration for a Tier P compute particle hack (storage buffer + atomic splat
/// pass resolved into the Tier S ping-pong `rgba16f` feedback canvas).
#[derive(Clone, Copy, Debug)]
pub struct Particles {
    /// Number of persistent particles in the GPU storage buffer (`array<Particle>`).
    pub count: u32,
}

/// Blend mode for Tier L instanced lines and shapes drawn onto the offscreen canvas.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineBlend {
    /// Premultiplied alpha (`src + dst * (1 - src.a)`): later instances paint over earlier
    /// ones, while outer halos add optically without darkening strokes behind them.
    Alpha,
    /// Additive (`src + dst`): overlapping strokes accumulate glow like a phosphor vector CRT.
    Add,
    /// Per-channel maximum (`max(src, dst)`): seamless round-capped polyline joins without bright knots.
    Max,
}

/// Configuration for a Tier L instanced line/shape hack (`shape(idx, t)` rendered as
/// instanced SDF quads into the offscreen target before the limiter and care pass).
#[derive(Clone, Copy, Debug)]
pub struct Lines {
    /// Number of primitive instances evaluated by `shape(idx, t)` each frame.
    pub count: u32,
    /// How primitives blend onto the offscreen target (and over `hack(p, t)`).
    pub blend: LineBlend,
}

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
    /// Uses Tier S ping-pong `rgba16f` feedback textures (`step_state`).
    pub feedback: Option<Feedback>,
    /// Uses Tier P persistent compute particles and atomic splats (`step_particle`, `resolve_state`).
    pub particles: Option<Particles>,
    /// Uses Tier L instanced SDF line/shape quads (`shape(idx, t)`).
    pub lines: Option<Lines>,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
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
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/moire-loom.wgsl"),
    },
    Hack {
        id: "julia-filigree",
        name: "Julia Filigree",
        about: "Luminous Julia-set filaments morphing across the dark (after Julia by Sean McCullough).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/julia-filigree.wgsl"),
    },
    Hack {
        id: "prism-barrel",
        name: "Prism Barrel",
        about: "Stained-glass shards and sweeping arcs tumbling through shifting mirror chambers (after Kaleidescope by Ron Tapia).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/prism-barrel.wgsl"),
    },
    Hack {
        id: "helix-tunnel",
        name: "Helix Tunnel",
        about: "Curving helical ribs, vortex bands and rushing starlight (after Atunnel by Roman Podobedov, Timetunnel by Sean Brennan and Wormhole by Jon Rafkind).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/helix-tunnel.wgsl"),
    },
    Hack {
        id: "pulsar-ridge",
        name: "Pulsar Ridge",
        about: "Hidden-line pulsar ridgelines scrolling across the dark (after Unknown Pleasures by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/pulsar-ridge.wgsl"),
    },
    Hack {
        id: "truchet-weave",
        name: "Truchet Weave",
        about: "Multi-scale interlaced Truchet arcs and chevron ribbons weaving across the dark (after Truchet by Adrian Likins).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/truchet-weave.wgsl"),
    },
    Hack {
        id: "voronoi-glass",
        name: "Voronoi Glass",
        about: "Drifting Voronoi cells with beveled crystal borders, faceted glass interiors and glowing nuclei (after Voronoi by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/voronoi-glass.wgsl"),
    },
    Hack {
        id: "apollonian-lace",
        name: "Apollonian Lace",
        about: "Nested tangent Apollonian circles and Mobius-drifting Descartes rings across the dark (after Apollonian by Allan R. Wilks and David Bagley).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/apollonian-lace.wgsl"),
    },
    Hack {
        id: "marble-vein",
        name: "Marble Vein",
        about: "Domain-warped marble veins and combed ebru ink ribbons folding across the dark (after Marbling by Jamie Zawinski and Dave Odell).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/marble-vein.wgsl"),
    },
    Hack {
        id: "flux-grid",
        name: "Flux Grid",
        about: "Undulating 3D wave-lattice canopy with wireframe ribs, faceted tiles and rolling sinusoidal swells across the dark (after Gflux by Josiah Pease and CWaves by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/flux-grid.wgsl"),
    },
    Hack {
        id: "lava-drift",
        name: "Lava Drift",
        about: "Buoyant 3D molten wax columns rising, merging into stretched necks and pinching apart across the dark (after Lavalite by Jamie Zawinski and Metaballs by W.P. van Paassen).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: true,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/lava-drift.wgsl"),
    },
    Hack {
        id: "klein-fold",
        name: "Klein Fold",
        about: "Sculptural 3D manifolds drifting and morphing across the dark between superquadrics, figure-8 Klein bottles and 4D hypertori (after Superquadrics by Ed Mackey, Klein and Hypertorus by Carsten Steger).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: true,
        feedback: None,
        particles: None,
        lines: None,
        source: include_str!("hacks/klein-fold.wgsl"),
    },
    Hack {
        id: "reagent-bloom",
        name: "Reagent Bloom",
        about: "Reaction-diffusion waves, curling spirals and coral blooms drifting across the dark (after RD-Bomb by Scott Draves).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 3.5,
            step_hz: 90.0,
            max_steps: 12,
            max_height: Some(240),
            wrap: true,
        }),
        particles: None,
        lines: None,
        source: include_str!("hacks/reagent-bloom.wgsl"),
    },
    Hack {
        id: "fault-strata",
        name: "Fault Strata",
        about: "Growing crystalline cracks halting in T-junctions with one-sided watercolor sand strata drifting across the dark (after Substrate by Jared Tarbell and Mike Kershaw).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 6.8,
            step_hz: 50.0,
            max_steps: 15,
            max_height: Some(240),
            wrap: true,
        }),
        particles: None,
        lines: None,
        source: include_str!("hacks/fault-strata.wgsl"),
    },
    Hack {
        id: "ember-plume",
        name: "Ember Plume",
        about: "Buoyant curling flames, glowing ember beds and drifting cinders rising across the dark (after XFlame by Carsten Haitzler).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 2.8,
            step_hz: 18.0,
            max_steps: 10,
            max_height: Some(240),
            wrap: true,
        }),
        particles: None,
        lines: None,
        source: include_str!("hacks/ember-plume.wgsl"),
    },
    Hack {
        id: "spore-cloud",
        name: "Spore Cloud",
        about: "Competing cellular-automaton colonies and age-limited Life clouds blooming, colliding and fading across the dark (after Cloudlife by Don Marti and Petri by Dan Bornstein).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 2.6,
            step_hz: 10.0,
            max_steps: 10,
            max_height: Some(96),
            wrap: true,
        }),
        particles: None,
        lines: None,
        source: include_str!("hacks/spore-cloud.wgsl"),
    },
    Hack {
        id: "crystal-reef",
        name: "Crystal Reef",
        about: "Branching coral dendrites and faceted frost crystals accreting and dissolving across the dark (after Coral by Frederick Roeber and Crystal by Jouk Jansen).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 5.8,
            step_hz: 14.0,
            max_steps: 14,
            max_height: Some(160),
            wrap: true,
        }),
        particles: None,
        lines: None,
        source: include_str!("hacks/crystal-reef.wgsl"),
    },
    Hack {
        id: "flame-veil",
        name: "Flame Veil",
        about: "Luminous iterated-function fractal flames and drifting IFS attractors woven across the dark (after Flame by Scott Draves and Patrick Naughton, and IFS by Pascal Massimino).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.22,
            step_hz: 30.0,
            max_steps: 1,
            max_height: Some(540),
            wrap: false,
        }),
        particles: Some(Particles { count: 16384 }),
        lines: None,
        source: include_str!("hacks/flame-veil.wgsl"),
    },
    Hack {
        id: "star-shell",
        name: "Star Shell",
        about: "Aerial chrysanthemum, willow, ring and strobe firework shells climbing and bursting into drifting spark trails across the dark (after Fireworkx by Rony B. Chandran and Pyro by Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.85,
            step_hz: 30.0,
            max_steps: 6,
            max_height: Some(540),
            wrap: false,
        }),
        particles: Some(Particles { count: 4096 }),
        lines: None,
        source: include_str!("hacks/star-shell.wgsl"),
    },
    Hack {
        id: "tidal-spiral",
        name: "Tidal Spiral",
        about: "Colliding 3D spiral galaxies pulling luminous tidal bridges and orbital star streams across the dark (after Galaxy by Uli Siegmund, Harald Backert and Hubert Feyrer, and Grav by Greg Bowering).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.13,
            step_hz: 30.0,
            max_steps: 4,
            max_height: Some(540),
            wrap: true,
        }),
        particles: Some(Particles { count: 12288 }),
        lines: None,
        source: include_str!("hacks/tidal-spiral.wgsl"),
    },
    Hack {
        id: "silk-flurry",
        name: "Silk Flurry",
        about: "Silky 3D plasma ribbons and luminous smoke tendrils streaming from orbiting sparks across the dark (after Flurry by Calum Robinson and Tobias Sargeant).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.22,
            step_hz: 60.0,
            max_steps: 4,
            max_height: Some(540),
            wrap: true,
        }),
        particles: Some(Particles { count: 12288 }),
        lines: None,
        source: include_str!("hacks/silk-flurry.wgsl"),
    },
    Hack {
        id: "fluid-beads",
        name: "Fluid Beads",
        about: "Luminous fluid beads sloshing, colliding and cascading through tilting gravity chambers across the dark (after Fluidballs by Peter Birtles and Jamie Zawinski).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.09,
            step_hz: 60.0,
            max_steps: 10,
            max_height: Some(540),
            wrap: true,
        }),
        particles: Some(Particles { count: 576 }),
        lines: None,
        source: include_str!("hacks/fluid-beads.wgsl"),
    },
    Hack {
        id: "silver-shoal",
        name: "Silver Shoal",
        about: "Bioluminescent boid schools and darting swarms weaving, banking and scattering across the dark (after GLSchool by David C. Lambert and Swarm by Jeff Butterworth).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.21,
            step_hz: 60.0,
            max_steps: 8,
            max_height: Some(540),
            wrap: true,
        }),
        particles: Some(Particles { count: 640 }),
        lines: None,
        source: include_str!("hacks/silver-shoal.wgsl"),
    },
    Hack {
        id: "wisp-swarm",
        name: "Wisp Swarm",
        about: "Translucent X-ray critter wakes and wind-casting scent seekers weaving glowing trails across the dark (after XRaySwarm by Chris Leger and Anemotaxis by Eugene Balkovsky).",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(Feedback {
            fade_secs: 0.52,
            step_hz: 60.0,
            max_steps: 8,
            max_height: Some(540),
            wrap: false,
        }),
        particles: Some(Particles { count: 512 }),
        lines: None,
        source: include_str!("hacks/wisp-swarm.wgsl"),
    },
    Hack {
        id: "departure-board",
        name: "Departure Board",
        about: "Split-flap rows from the other tools on the desk: states and counts, never titles.",
        text_heavy: true,
        hue_turn: false,
        board: true,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
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

    #[test]
    fn particle_hacks_require_feedback_and_nonzero_count() {
        for h in HACKS {
            if let Some(p) = h.particles {
                assert!(h.feedback.is_some(), "{} uses particles without feedback", h.id);
                assert!(p.count > 0, "{} has zero particles", h.id);
                assert!(!h.board, "{} mixes board and particles", h.id);
            }
        }
    }

    #[test]
    fn line_hacks_require_nonzero_count() {
        for h in HACKS {
            if let Some(l) = h.lines {
                assert!(l.count > 0, "{} has zero line instances", h.id);
            }
        }
    }
}
