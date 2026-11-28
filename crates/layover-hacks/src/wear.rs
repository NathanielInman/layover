//! The wear test (rule five): render a hack headless through the care pass
//! for a simulated stretch, one frame per second, and add up the light every
//! pixel gives off. See "The wear test" in `docs/design.md`.

use crate::Hack;
use crate::gpu::Gpu;
use crate::renderer::{CareSettings, Frame, Placement, Renderer};
use anyhow::{Context, Result};
use layover_core::config::Care;
use std::path::Path;

/// A lit pixel: above this level after the care pass. A quarter of the
/// shipped drive: the limiter can dim a still frame to just under a higher
/// line, and a dim still frame still wears unevenly.
pub const LIT: f32 = 0.15;
/// A pixel that moved by less than this in a second has not changed.
pub const STILL: f32 = 0.03;
/// No channel may carry more than this share of the light.
pub const MAX_SHARE: f32 = 0.40;

/// The G9's canvas: two 2560 × 1440 outputs side by side.
pub const G9_CANVAS: [f32; 2] = [5120.0, 1440.0];

#[derive(Clone, Debug)]
pub struct Budget {
    pub max_average: f32,
    pub max_dwell_secs: u32,
    pub max_hot_spot: f32,
    pub max_share: f32,
    pub max_drive: f32,
}

impl Budget {
    pub fn from_care(c: &Care) -> Budget {
        Budget {
            max_average: c.max_average,
            max_dwell_secs: c.max_dwell.0.as_secs() as u32,
            max_hot_spot: c.max_hot_spot,
            max_share: MAX_SHARE,
            max_drive: c.max_drive,
        }
    }
}

#[derive(Clone, Debug)]
pub struct WearReport {
    pub hack: &'static str,
    pub seconds: u32,
    pub size: [u32; 2],
    /// Mean level over every pixel and frame, 0..1.
    pub average: f32,
    /// Longest run of seconds any pixel stayed lit and unchanged.
    pub max_dwell_secs: u32,
    /// The highest per-pixel mean level.
    pub hot_spot: f32,
    /// Red, green and blue as shares of all light.
    pub share: [f32; 3],
    /// The brightest subpixel seen, 0..1.
    pub peak: f32,
    /// Per-pixel mean level, row by row.
    pub heat: Vec<f32>,
}

impl WearReport {
    /// Every budget this run broke, as sentences.
    pub fn failures(&self, b: &Budget) -> Vec<String> {
        let mut out = Vec::new();
        // The limiter samples a grid and eases toward its target, so allow a
        // sliver over the line before calling it a failure.
        if self.average > b.max_average + 0.005 {
            out.push(format!("average level {:.3} is over {:.3}", self.average, b.max_average));
        }
        if self.max_dwell_secs > b.max_dwell_secs {
            out.push(format!(
                "a pixel stayed lit and unchanged for {}s, over {}s",
                self.max_dwell_secs, b.max_dwell_secs
            ));
        }
        if self.hot_spot > b.max_hot_spot {
            out.push(format!(
                "the hottest area averaged {:.3}, over {:.3}",
                self.hot_spot, b.max_hot_spot
            ));
        }
        for (name, s) in ["red", "green", "blue"].iter().zip(self.share) {
            if s > b.max_share {
                out.push(format!(
                    "{name} carried {:.0}% of the light, over {:.0}%",
                    s * 100.0,
                    b.max_share * 100.0
                ));
            }
        }
        if self.peak > b.max_drive + 1.0 / 255.0 {
            out.push(format!("a subpixel reached {:.3}, over {:.3}", self.peak, b.max_drive));
        }
        out
    }

    pub fn summary(&self) -> String {
        format!(
            "{}: average {:.1}%, longest lit dwell {}s, hottest area {:.1}%, R·G·B {:.0}·{:.0}·{:.0}%, peak {:.0}% ({}s at {}×{})",
            self.hack,
            self.average * 100.0,
            self.max_dwell_secs,
            self.hot_spot * 100.0,
            self.share[0] * 100.0,
            self.share[1] * 100.0,
            self.share[2] * 100.0,
            self.peak * 100.0,
            self.seconds,
            self.size[0],
            self.size[1],
        )
    }

    /// Write the heat map as a PNG, `scale` times the test size.
    pub fn write_heat_png(&self, path: &Path, scale: u32) -> Result<()> {
        let [w, h] = self.size;
        let (sw, sh) = (w * scale, h * scale);
        let mut data = Vec::with_capacity((sw * sh * 3) as usize);
        for y in 0..sh {
            for x in 0..sw {
                let v = self.heat[((y / scale) * w + x / scale) as usize];
                data.extend_from_slice(&ramp(v / 0.4));
            }
        }
        let file =
            std::fs::File::create(path).with_context(|| format!("creating {}", path.display()))?;
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), sw, sh);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header()?;
        writer.write_image_data(&data)?;
        Ok(())
    }
}

/// Black, plum, mauve, amber, white: more heat, more wear.
fn ramp(x: f32) -> [u8; 3] {
    const STOPS: [[f32; 3]; 5] = [
        [0.0, 0.0, 0.0],
        [59.0, 31.0, 74.0],
        [180.0, 142.0, 173.0],
        [235.0, 203.0, 139.0],
        [255.0, 255.0, 255.0],
    ];
    let x = x.clamp(0.0, 1.0) * 4.0;
    let i = (x.floor() as usize).min(3);
    let f = x - i as f32;
    let (a, b) = (STOPS[i], STOPS[i + 1]);
    [0, 1, 2].map(|k| (a[k] + (b[k] - a[k]) * f).round() as u8)
}

/// Render `hack` for `seconds` at `size`, one frame per second.
pub fn run(
    gpu: &Gpu,
    hack: &'static Hack,
    care: &CareSettings,
    seconds: u32,
    size: [u32; 2],
    canvas: [f32; 2],
) -> Result<WearReport> {
    let device = &gpu.device;
    let mut renderer = Renderer::new(device, &gpu.queue, care.clone());
    renderer.resize(canvas, size);
    renderer.reset_limiter();
    renderer.reset_state();
    renderer.prepare(hack)?;
    if hack.board {
        renderer.set_board(&crate::board::BoardData::sample());
    }

    let format = wgpu::TextureFormat::Rgba8Unorm;
    let target = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("wear"),
        size: wgpu::Extent3d { width: size[0], height: size[1], depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = target.create_view(&Default::default());
    let row = (size[0] * 4).div_ceil(256) * 256;
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("wear readback"),
        size: (row * size[1]) as u64,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let place = Placement { rect: [0.0, 0.0, canvas[0], canvas[1]], px: size };

    let n = (size[0] * size[1]) as usize;
    let mut sum = vec![0f64; n];
    let mut prev = vec![0f32; n];
    let mut dwell = vec![0u32; n];
    let mut max_dwell = 0u32;
    let mut channels = [0f64; 3];
    let mut peak = 0u8;

    for s in 0..seconds {
        let t = s as f32;
        let frame = Frame { hack, t, phase: t as f64, dt: 1.0, seed: 0.37 };
        let mut enc = device.create_command_encoder(&Default::default());
        renderer.draw_canvas(&mut enc, &frame)?;
        renderer.draw_output(&mut enc, 0, &view, format, &place, 1.0)?;
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(size[1]),
                },
            },
            wgpu::Extent3d { width: size[0], height: size[1], depth_or_array_layers: 1 },
        );
        gpu.queue.submit(Some(enc.finish()));
        readback.map_async(wgpu::MapMode::Read, .., |r| r.expect("mapping the wear readback"));
        device
            .poll(wgpu::PollType::Wait { submission_index: None, timeout: None })
            .context("waiting for the GPU")?;
        {
            let bytes = readback.get_mapped_range(..).context("reading back the frame")?;
            for y in 0..size[1] as usize {
                let line = &bytes[y * row as usize..];
                for x in 0..size[0] as usize {
                    let px = &line[x * 4..x * 4 + 4];
                    let i = y * size[0] as usize + x;
                    let (r, g, b) = (px[0], px[1], px[2]);
                    channels[0] += r as f64;
                    channels[1] += g as f64;
                    channels[2] += b as f64;
                    peak = peak.max(r).max(g).max(b);
                    let level = (r as f32 + g as f32 + b as f32) / 765.0;
                    sum[i] += level as f64;
                    if level > LIT && (level - prev[i]).abs() < STILL {
                        dwell[i] += 1;
                        max_dwell = max_dwell.max(dwell[i]);
                    } else {
                        dwell[i] = 0;
                    }
                    prev[i] = level;
                }
            }
        }
        readback.unmap();
    }

    let frames = seconds.max(1) as f64;
    let heat: Vec<f32> = sum.iter().map(|s| (s / frames) as f32).collect();
    let average = (heat.iter().map(|h| *h as f64).sum::<f64>() / n as f64) as f32;
    let hot_spot = heat.iter().cloned().fold(0.0, f32::max);
    let total = channels.iter().sum::<f64>().max(1.0);
    Ok(WearReport {
        hack: hack.id,
        seconds,
        size,
        average,
        max_dwell_secs: max_dwell,
        hot_spot,
        share: channels.map(|c| (c / total) as f32),
        peak: peak as f32 / 255.0,
        heat,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::HACKS;

    fn gpu() -> Option<Gpu> {
        if std::env::var_os("LAYOVER_SKIP_GPU_TESTS").is_some() {
            eprintln!("LAYOVER_SKIP_GPU_TESTS is set: skipping a GPU test");
            return None;
        }
        Some(Gpu::headless().expect("the wear test needs a Vulkan adapter (CI uses lavapipe)"))
    }

    fn shipped() -> (CareSettings, Budget) {
        let care = Care::default();
        (CareSettings::from_config(&care), Budget::from_care(&care))
    }

    /// Rule five: every hack passes an hour on the G9 against the shipped budget.
    #[test]
    fn every_hack_passes_an_hour_on_the_g9() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let mut failed = Vec::new();
        for hack in HACKS {
            let report = run(&gpu, hack, &care, 3600, [256, 72], G9_CANVAS).unwrap();
            eprintln!("{}", report.summary());
            let f = report.failures(&budget);
            if !f.is_empty() {
                failed.push(format!("{}: {}", hack.id, f.join("; ")));
            }
        }
        assert!(failed.is_empty(), "hacks broke rule one:\n{}", failed.join("\n"));
    }

    /// Hacks still pass on an ordinary 16:9 screen.
    #[test]
    fn every_hack_passes_ten_minutes_at_16_by_9() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        for hack in HACKS {
            let report = run(&gpu, hack, &care, 600, [128, 72], [2560.0, 1440.0]).unwrap();
            let f = report.failures(&budget);
            assert!(f.is_empty(), "{} at 16:9: {}", hack.id, f.join("; "));
        }
    }

    static STILL_HACK: Hack = Hack {
        id: "still",
        name: "Still",
        about: "A bright patch that never moves, like a clock left on screen.",
        text_heavy: false,
        hue_turn: false,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: None,
        source: "fn hack(p: vec2<f32>, t: f32) -> vec3<f32> { let on = step(1.6, p.x) * step(p.x, 2.0) * step(0.4, p.y) * step(p.y, 0.6); return vec3<f32>(on * 0.9); }",
    };

    static WHITE_HACK: Hack = Hack {
        id: "white",
        name: "White",
        about: "Every pixel full white, changing.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: None,
        source: "fn hack(p: vec2<f32>, t: f32) -> vec3<f32> { return vec3<f32>(0.8 + 0.2 * sin(t * 3.0 + p.x * 40.0)); }",
    };

    static UNFADED_STATEFUL_HACK: Hack = Hack {
        id: "unfed-stateful",
        name: "Unfaded Stateful",
        about: "A stateful hack that paints a patch on frame 0 and never fades it.",
        text_heavy: false,
        hue_turn: false,
        board: false,
        raymarch: false,
        feedback: Some(crate::Feedback {
            fade_secs: 0.0,
            step_hz: 1.0,
            max_steps: 1,
            max_height: None,
            wrap: false,
        }),
        particles: None,
        lines: None,
        mesh: None,
        source: r#"
fn step_state(uv: vec2<f32>, p: vec2<f32>, _t: f32) -> vec4<f32> {
    if (g.frame < 0.5) {
        let on = step(1.6, p.x) * step(p.x, 2.0) * step(0.4, p.y) * step(p.y, 0.6);
        return vec4<f32>(vec3<f32>(on * 0.9), 1.0);
    }
    return state_faded(uv);
}
fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    return state_sample(state_uv(p)).rgb;
}
"#,
    };

    static FADING_STATEFUL_HACK: Hack = Hack {
        id: "fading-stateful",
        name: "Fading Stateful",
        about: "A moving disc leaving a fading trail in state.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(crate::Feedback {
            fade_secs: 3.0,
            step_hz: 1.0,
            max_steps: 1,
            max_height: None,
            wrap: false,
        }),
        particles: None,
        lines: None,
        mesh: None,
        source: r#"
fn step_state(uv: vec2<f32>, p: vec2<f32>, t: f32) -> vec4<f32> {
    let prev = state_faded(uv).rgb;
    let a = aspect();
    let c = vec2<f32>(a * (0.5 + 0.35 * sin(t * 0.7)), 0.5 + 0.32 * cos(t * 1.1));
    let m = disc(length(p - c), 0.14, 0.04);
    let col = 0.5 + 0.5 * cos(t * 0.9 + vec3<f32>(0.0, 2.094, 4.188));
    return vec4<f32>(max(prev, col * m), 1.0);
}
fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    return state_sample(state_uv(p)).rgb;
}
"#,
    };

    static UNFADED_PARTICLE_HACK: Hack = Hack {
        id: "unfed-particle",
        name: "Unfaded Particle",
        about: "A compute particle hack that splats a still cluster on frame 0 and never fades it.",
        text_heavy: false,
        hue_turn: false,
        board: false,
        raymarch: false,
        feedback: Some(crate::Feedback {
            fade_secs: 0.0,
            step_hz: 1.0,
            max_steps: 1,
            max_height: None,
            wrap: false,
        }),
        particles: Some(crate::Particles { count: 256 }),
        lines: None,
        mesh: None,
        source: r#"
fn step_particle(idx: u32, _t: f32) {
    if (g.frame < 0.5) {
        let fx = f32(idx % 16u) / 15.0;
        let fy = f32(idx / 16u) / 15.0;
        let pos = vec2<f32>(1.65 + fx * 0.30, 0.40 + fy * 0.22);
        splat_point(pos, vec3<f32>(0.9), 1.0);
    }
}
fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    return clamp(state_faded(uv) + splat, vec4<f32>(0.0), vec4<f32>(1.0));
}
fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    return state_sample(state_uv(p)).rgb;
}
"#,
    };

    static FADING_PARTICLE_HACK: Hack = Hack {
        id: "fading-particle",
        name: "Fading Particle",
        about: "Compute particles orbiting across the canvas and leaving fading trails.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(crate::Feedback {
            fade_secs: 2.5,
            step_hz: 1.0,
            max_steps: 1,
            max_height: None,
            wrap: false,
        }),
        particles: Some(crate::Particles { count: 256 }),
        lines: None,
        mesh: None,
        source: r#"
fn step_particle(idx: u32, t: f32) {
    let fi = f32(idx);
    let a = aspect();
    let phase = fi * 0.02454369 + g.seed * TAU;
    let c = vec2<f32>(
        a * (0.5 + 0.38 * sin(t * 0.53 + phase)),
        0.5 + 0.34 * cos(t * 0.71 + phase * 1.7)
    );
    let col = 0.5 + 0.5 * cos(t * 0.4 + phase + vec3<f32>(0.0, 2.094, 4.188));
    splat_disc(c, 0.08, col * 0.85, 1.0, false);
}
fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    return clamp(state_faded(uv) + splat * 0.4, vec4<f32>(0.0), vec4<f32>(1.0));
}
fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    return state_sample(state_uv(p)).rgb;
}
"#,
    };

    static STILL_LINE_HACK: Hack = Hack {
        id: "still-line",
        name: "Still Line",
        about: "A bright static segment that never moves.",
        text_heavy: false,
        hue_turn: false,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: Some(crate::Lines { count: 1, blend: crate::LineBlend::Alpha }),
        mesh: None,
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn shape(_idx: u32, _t: f32) -> Shape {
    return shape_segment(
        vec2<f32>(1.3, 0.5),
        vec2<f32>(2.2, 0.5),
        0.18,
        vec4<f32>(0.9, 0.9, 0.9, 1.0),
    );
}
"#,
    };

    static MOVING_LINE_HACK: Hack = Hack {
        id: "moving-line",
        name: "Moving Line",
        about: "Instanced lines, discs, rings, arcs, boxes and triangles sweeping across the canvas.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: Some(crate::Lines { count: 32, blend: crate::LineBlend::Max }),
        mesh: None,
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn shape(idx: u32, t: f32) -> Shape {
    let total = max(line_count(), 1u);
    let fi = f32(idx);
    let a = aspect();
    let ph = fi * 0.61803399 * TAU + g.seed * TAU;
    let c = vec2<f32>(
        a * (0.5 + 0.36 * sin(t * 0.45 + ph)),
        0.5 + 0.34 * cos(t * 0.63 + ph * 1.3),
    );
    let rgb_a = 0.5 + 0.45 * cos(t * 0.5 + ph + vec3<f32>(0.0, 2.094, 4.188));
    let rgb_b = 0.5 + 0.45 * cos(t * 0.5 + ph + 1.2 + vec3<f32>(0.0, 2.094, 4.188));
    let col_a = vec4<f32>(rgb_a, 1.0);
    let col_b = vec4<f32>(rgb_b, 1.0);

    if (idx >= total - 2u) {
        return shape_none();
    }
    if (idx < 10u) {
        let off = vec2<f32>(0.24 * cos(t * 0.7 + ph), 0.16 * sin(t * 0.9 + ph));
        return shape_glow(
            shape_segment_taper(c - off, c + off, 0.04, 0.08, col_a, col_b, 0.0),
            0.04,
            0.35,
        );
    }
    if (idx < 16u) {
        return shape_grad(shape_disc(c, 0.065, col_a, 0.04), col_b);
    }
    if (idx < 18u) {
        return shape_grad(shape_ring(c, 0.16, 0.045, col_a, 0.03), col_b);
    }
    if (idx < 20u) {
        return shape_arc(c, 0.17, 0.045, t * 0.9 + ph, 1.35, col_a, col_b, 0.03);
    }
    if (idx < 24u) {
        let stroke = select(0.0, 0.035, (idx & 1u) != 0u);
        return shape_grad(
            shape_box(c, vec2<f32>(0.09, 0.06), t * 0.8 + ph, 0.02, stroke, col_a, 0.03),
            col_b,
        );
    }
    if (idx < 28u) {
        let stroke = select(0.0, 0.035, (idx & 1u) != 0u);
        let ang = t * 0.75 + ph;
        let r = 0.09;
        let p0 = c + vec2<f32>(cos(ang), sin(ang)) * r;
        let p1 = c + vec2<f32>(cos(ang + 2.094), sin(ang + 2.094)) * r;
        let p2 = c + vec2<f32>(cos(ang + 4.188), sin(ang + 4.188)) * r;
        return shape_grad(shape_triangle(p0, p1, p2, stroke, col_a, 0.03), col_b);
    }
    let off = vec2<f32>(0.22 * sin(t * 0.8 + ph), 0.14 * cos(t * 0.6 + ph));
    return shape_glow(
        shape_grad(shape_segment(c - off, c + off, 0.055, col_a), col_b),
        0.04,
        0.4,
    );
}
"#,
    };

    static OVERDRIVEN_ADD_LINE_HACK: Hack = Hack {
        id: "overdriven-add-line",
        name: "Overdriven Add Line",
        about: "Overlapping additive lines held under the care limits.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: Some(crate::Lines { count: 40, blend: crate::LineBlend::Add }),
        mesh: None,
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn shape(idx: u32, t: f32) -> Shape {
    let fi = f32(idx);
    let a = aspect();
    let y = 0.25 + 0.5 * fract(0.13 * fi + t * 0.08);
    return shape_segment(
        vec2<f32>(0.2 * a, y),
        vec2<f32>(0.8 * a, y),
        0.16,
        vec4<f32>(0.95, 0.95, 0.95, 1.0),
    );
}
"#,
    };

    static HAIRLINE_LINE_HACK: Hack = Hack {
        id: "hairline-line",
        name: "Hairline Line",
        about: "Subpixel hairline segments retaining visibility under energy-conserving AA.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: Some(crate::Lines { count: 8, blend: crate::LineBlend::Alpha }),
        mesh: None,
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn shape(idx: u32, t: f32) -> Shape {
    let fi = f32(idx);
    let a = aspect();
    let y = fract(0.125 * fi + t * 0.23);
    return shape_segment(
        vec2<f32>(0.05 * a, y),
        vec2<f32>(0.95 * a, 1.0 - y),
        0.004,
        vec4<f32>(0.9, 0.85, 0.8, 1.0),
    );
}
"#,
    };

    static FEEDBACK_AND_LINE_HACK: Hack = Hack {
        id: "feedback-and-line",
        name: "Feedback And Line",
        about: "Combines Tier S feedback state with Tier L instanced lines.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(crate::Feedback {
            fade_secs: 2.5,
            step_hz: 1.0,
            max_steps: 1,
            max_height: None,
            wrap: false,
        }),
        particles: None,
        lines: Some(crate::Lines { count: 8, blend: crate::LineBlend::Max }),
        mesh: None,
        source: r#"
fn step_state(uv: vec2<f32>, p: vec2<f32>, t: f32) -> vec4<f32> {
    let prev = state_faded(uv).rgb;
    let a = aspect();
    let c = vec2<f32>(a * (0.5 + 0.35 * sin(t * 0.7)), 0.5 + 0.3 * cos(t * 1.1));
    let m = disc(length(p - c), 0.14, 0.04);
    let col = 0.35 + 0.25 * cos(t * 0.8 + vec3<f32>(0.0, 2.094, 4.188));
    return vec4<f32>(max(prev, col * m), 1.0);
}
fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    return state_sample(state_uv(p)).rgb;
}
fn shape(idx: u32, t: f32) -> Shape {
    let fi = f32(idx);
    let a = aspect();
    let ph = fi * 0.7854 + t * 0.8;
    let c = vec2<f32>(a * (0.5 + 0.35 * cos(ph)), 0.5 + 0.3 * sin(ph * 1.3));
    let col = vec4<f32>(0.5 + 0.4 * sin(t + fi + vec3<f32>(0.0, 2.094, 4.188)), 1.0);
    return shape_ring(c, 0.12, 0.04, col, 0.02);
}
"#,
    };

    static ZERO_LINES_HACK: Hack = Hack {
        id: "zero-lines",
        name: "Zero Lines",
        about: "Invalid zero-instance Tier L hack.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: Some(crate::Lines { count: 0, blend: crate::LineBlend::Alpha }),
        mesh: None,
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn shape(_idx: u32, _t: f32) -> Shape {
    return shape_none();
}
"#,
    };

    fn custom_tetrahedron() -> crate::MeshData {
        use crate::{MeshData, MeshVertex};
        let p =
            [[0.0f32, 0.5, 0.0], [-0.45, -0.35, 0.35], [0.45, -0.35, 0.35], [0.0, -0.35, -0.45]];
        let faces = [[0, 1, 2], [0, 2, 3], [0, 3, 1], [1, 3, 2]];
        let mut vertices = Vec::with_capacity(12);
        let mut indices = Vec::with_capacity(12);
        for [i0, i1, i2] in faces {
            let (a, b, c) = (p[i0], p[i1], p[i2]);
            let e1 = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
            let e2 = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
            let n = [
                e1[1] * e2[2] - e1[2] * e2[1],
                e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0],
            ];
            let l = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt().max(1e-6);
            let normal = [n[0] / l, n[1] / l, n[2] / l];
            let base = vertices.len() as u32;
            vertices.push(MeshVertex { pos: a, normal, uv: [0.0, 0.0] });
            vertices.push(MeshVertex { pos: b, normal, uv: [1.0, 0.0] });
            vertices.push(MeshVertex { pos: c, normal, uv: [0.5, 1.0] });
            indices.extend_from_slice(&[base, base + 1, base + 2]);
        }
        MeshData { vertices, indices }
    }

    fn bad_custom_mesh() -> crate::MeshData {
        use crate::{MeshData, MeshVertex};
        MeshData {
            vertices: vec![MeshVertex { pos: [0.0; 3], normal: [0.0, 1.0, 0.0], uv: [0.0; 2] }],
            indices: vec![0, 1, 2],
        }
    }

    static STILL_MESH_DRAWS: &[crate::MeshDraw] =
        &[crate::MeshDraw { mesh: crate::MeshSource::Cube, instances: 1 }];

    static STILL_MESH_HACK: Hack = Hack {
        id: "still-mesh",
        name: "Still Mesh",
        about: "A bright static 3D cube that never moves.",
        text_heavy: false,
        hue_turn: false,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: STILL_MESH_DRAWS, cull: crate::MeshCull::Back }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn mesh_camera(_t: f32) -> MeshCamera {
    return mesh_camera_persp(vec3<f32>(0.0, 0.0, 3.0), vec3<f32>(0.0), 0.9, 0.1, 20.0);
}
fn mesh_instance(_draw: u32, _inst: u32, _t: f32) -> MeshInstance {
    let inst = mesh_instance_trs(vec3<f32>(0.0), vec3<f32>(0.0), vec3<f32>(1.1), vec3<f32>(0.9));
    return mesh_material(inst, 0.3, 0.1, 0.4, vec3<f32>(0.85));
}
"#,
    };

    static MOVING_MESH_DRAWS: &[crate::MeshDraw] = &[
        crate::MeshDraw { mesh: crate::MeshSource::Cube, instances: 6 },
        crate::MeshDraw { mesh: crate::MeshSource::Sphere, instances: 4 },
        crate::MeshDraw { mesh: crate::MeshSource::Cylinder, instances: 3 },
        crate::MeshDraw { mesh: crate::MeshSource::Torus, instances: 3 },
        crate::MeshDraw { mesh: crate::MeshSource::Gear, instances: 3 },
        crate::MeshDraw { mesh: crate::MeshSource::Custom(custom_tetrahedron), instances: 2 },
    ];

    static MOVING_MESH_HACK: Hack = Hack {
        id: "moving-mesh",
        name: "Moving Mesh",
        about: "Orbiting, connected and tumbling 3D mesh primitives under depth testing.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: MOVING_MESH_DRAWS, cull: crate::MeshCull::Back }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn mesh_camera(t: f32) -> MeshCamera {
    let eye = vec3<f32>(0.35 * sin(t * 0.25), 0.25 * cos(t * 0.19), 3.2);
    return mesh_camera_persp(eye, vec3<f32>(0.0), 0.95, 0.1, 30.0);
}
fn mesh_instance(draw: u32, inst: u32, t: f32) -> MeshInstance {
    if (draw == 0u && inst + 1u == mesh_instance_count()) {
        return mesh_instance_none();
    }
    let id = f32(draw * 7u + inst);
    let ph = id * 0.91 + g.seed * TAU;
    let half_w = aspect() * 0.72;
    let pos = vec3<f32>(
        half_w * sin(t * 0.42 + ph),
        0.58 * cos(t * 0.57 + ph * 1.3),
        0.45 * sin(t * 0.36 - ph),
    );
    let col = 0.5 + 0.42 * cos(t * 0.45 + ph + vec3<f32>(0.0, 2.094, 4.188));
    if (draw == 2u) {
        let a = pos + vec3<f32>(0.22 * cos(t + ph), 0.18 * sin(t * 1.1 + ph), 0.0);
        let b = pos - vec3<f32>(0.22 * cos(t + ph), 0.18 * sin(t * 1.1 + ph), 0.0);
        return mesh_material(mesh_instance_mat(mesh_from_to(a, b, 0.07), col), 0.28, 0.35, 0.5, vec3<f32>(0.04));
    }
    let rot = vec3<f32>(t * 0.8 + ph, t * 1.1 - ph * 0.5, t * 0.6);
    let item = mesh_instance_trs(pos, rot, vec3<f32>(0.34), col);
    return mesh_material(item, 0.32, 0.30, 0.55, col * 0.05);
}
"#,
    };

    static DEPTH_OCCLUSION_DRAWS: &[crate::MeshDraw] = &[
        crate::MeshDraw { mesh: crate::MeshSource::Cube, instances: 1 },
        crate::MeshDraw { mesh: crate::MeshSource::Cube, instances: 1 },
    ];

    static DEPTH_OCCLUSION_HACK: Hack = Hack {
        id: "depth-occlusion",
        name: "Depth Occlusion",
        about: "Draws a near green cube before a far red cube to test Z-buffering.",
        text_heavy: false,
        hue_turn: false,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: DEPTH_OCCLUSION_DRAWS, cull: crate::MeshCull::Back }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn mesh_camera(_t: f32) -> MeshCamera {
    return mesh_camera_ortho(vec3<f32>(0.0, 0.0, 5.0), vec3<f32>(0.0), 1.0, 0.5, 20.0);
}
fn mesh_instance(draw: u32, _inst: u32, _t: f32) -> MeshInstance {
    if (draw == 0u) {
        let near = mesh_instance_trs(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0), vec3<f32>(0.4), vec3<f32>(0.0));
        return mesh_material(near, 0.5, 0.0, 0.0, vec3<f32>(0.0, 0.9, 0.0));
    }
    let far = mesh_instance_trs(vec3<f32>(0.0, 0.0, -1.0), vec3<f32>(0.0), vec3<f32>(1.4), vec3<f32>(0.0));
    return mesh_material(far, 0.5, 0.0, 0.0, vec3<f32>(0.9, 0.0, 0.0));
}
"#,
    };

    static COMPOSED_MESH_DRAWS: &[crate::MeshDraw] =
        &[crate::MeshDraw { mesh: crate::MeshSource::Octahedron, instances: 6 }];

    static FEEDBACK_MESH_AND_LINE_HACK: Hack = Hack {
        id: "feedback-mesh-line",
        name: "Feedback Mesh And Line",
        about: "Composes Tier S feedback, Tier M meshes and Tier L lines together.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: Some(crate::Feedback {
            fade_secs: 2.5,
            step_hz: 1.0,
            max_steps: 1,
            max_height: None,
            wrap: false,
        }),
        particles: None,
        lines: Some(crate::Lines { count: 6, blend: crate::LineBlend::Max }),
        mesh: Some(crate::Mesh { draws: COMPOSED_MESH_DRAWS, cull: crate::MeshCull::Back }),
        source: r#"
fn step_state(uv: vec2<f32>, p: vec2<f32>, t: f32) -> vec4<f32> {
    let prev = state_faded(uv).rgb;
    let a = aspect();
    let c = vec2<f32>(a * (0.5 + 0.35 * sin(t * 0.7)), 0.5 + 0.3 * cos(t * 1.1));
    let m = disc(length(p - c), 0.14, 0.04);
    let col = 0.35 + 0.25 * cos(t * 0.8 + vec3<f32>(0.0, 2.094, 4.188));
    return vec4<f32>(max(prev, col * m), 1.0);
}
fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    return state_sample(state_uv(p)).rgb;
}
fn mesh_camera(_t: f32) -> MeshCamera {
    return mesh_camera_persp(vec3<f32>(0.0, 0.0, 3.2), vec3<f32>(0.0), 0.9, 0.1, 20.0);
}
fn mesh_instance(_draw: u32, inst: u32, t: f32) -> MeshInstance {
    let ph = f32(inst) * 1.0472 + t * 0.65;
    let pos = vec3<f32>(aspect() * 0.6 * sin(ph), 0.55 * cos(ph * 1.3), 0.25 * cos(ph));
    let col = 0.5 + 0.4 * cos(t * 0.5 + ph + vec3<f32>(0.0, 2.094, 4.188));
    return mesh_instance_trs(pos, vec3<f32>(ph, ph * 0.7, 0.0), vec3<f32>(0.34), col);
}
fn shape(idx: u32, t: f32) -> Shape {
    let fi = f32(idx);
    let ph = fi * 1.0472 + t * 0.8;
    let c = vec2<f32>(aspect() * (0.5 + 0.35 * cos(ph)), 0.5 + 0.3 * sin(ph * 1.3));
    let col = vec4<f32>(0.5 + 0.4 * sin(t + fi + vec3<f32>(0.0, 2.094, 4.188)), 1.0);
    return shape_ring(c, 0.10, 0.035, col, 0.02);
}
"#,
    };

    static OVERDRIVEN_MESH_DRAWS: &[crate::MeshDraw] =
        &[crate::MeshDraw { mesh: crate::MeshSource::Cube, instances: 4 }];

    static OVERDRIVEN_MESH_HACK: Hack = Hack {
        id: "overdriven-mesh",
        name: "Overdriven Mesh",
        about: "Large bright emissive cubes held under the care limits.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: OVERDRIVEN_MESH_DRAWS, cull: crate::MeshCull::None }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}
fn mesh_camera(_t: f32) -> MeshCamera {
    return mesh_camera_ortho(vec3<f32>(0.0, 0.0, 5.0), vec3<f32>(0.0), 1.0, 0.5, 20.0);
}
fn mesh_instance(_draw: u32, inst: u32, t: f32) -> MeshInstance {
    let off = (f32(inst) - 1.5) * 0.9 + 0.15 * sin(t + f32(inst));
    let m = mesh_instance_trs(vec3<f32>(off, 0.0, 0.0), vec3<f32>(t * 0.3), vec3<f32>(1.2), vec3<f32>(1.0));
    return mesh_material(m, 0.5, 0.0, 0.2, vec3<f32>(1.0));
}
"#,
    };

    static EMPTY_MESH_HACK: Hack = Hack {
        id: "empty-mesh",
        name: "Empty Mesh",
        about: "Invalid empty Tier M draw list.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: &[], cull: crate::MeshCull::Back }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> { return vec3<f32>(0.0); }
fn mesh_camera(_t: f32) -> MeshCamera { return mesh_camera_ortho(vec3<f32>(0.0, 0.0, 2.0), vec3<f32>(0.0), 1.0, 0.1, 10.0); }
fn mesh_instance(_draw: u32, _inst: u32, _t: f32) -> MeshInstance { return mesh_instance_none(); }
"#,
    };

    static ZERO_INSTANCES_MESH_DRAWS: &[crate::MeshDraw] =
        &[crate::MeshDraw { mesh: crate::MeshSource::Cube, instances: 0 }];

    static ZERO_INSTANCES_MESH_HACK: Hack = Hack {
        id: "zero-inst-mesh",
        name: "Zero Instance Mesh",
        about: "Invalid Tier M draw with zero instances.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: ZERO_INSTANCES_MESH_DRAWS, cull: crate::MeshCull::Back }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> { return vec3<f32>(0.0); }
fn mesh_camera(_t: f32) -> MeshCamera { return mesh_camera_ortho(vec3<f32>(0.0, 0.0, 2.0), vec3<f32>(0.0), 1.0, 0.1, 10.0); }
fn mesh_instance(_draw: u32, _inst: u32, _t: f32) -> MeshInstance { return mesh_instance_none(); }
"#,
    };

    static BAD_CUSTOM_MESH_DRAWS: &[crate::MeshDraw] =
        &[crate::MeshDraw { mesh: crate::MeshSource::Custom(bad_custom_mesh), instances: 1 }];

    static BAD_CUSTOM_MESH_HACK: Hack = Hack {
        id: "bad-custom-mesh",
        name: "Bad Custom Mesh",
        about: "Invalid Tier M custom geometry with out-of-bounds indices.",
        text_heavy: false,
        hue_turn: true,
        board: false,
        raymarch: false,
        feedback: None,
        particles: None,
        lines: None,
        mesh: Some(crate::Mesh { draws: BAD_CUSTOM_MESH_DRAWS, cull: crate::MeshCull::Back }),
        source: r#"
fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> { return vec3<f32>(0.0); }
fn mesh_camera(_t: f32) -> MeshCamera { return mesh_camera_ortho(vec3<f32>(0.0, 0.0, 2.0), vec3<f32>(0.0), 1.0, 0.1, 10.0); }
fn mesh_instance(_draw: u32, _inst: u32, _t: f32) -> MeshInstance { return mesh_instance_none(); }
"#,
    };

    /// The test catches what it exists to catch.
    #[test]
    fn a_still_patch_fails_the_dwell_budget() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &STILL_HACK, &care, 60, [64, 18], G9_CANVAS).unwrap();
        assert!(report.max_dwell_secs > budget.max_dwell_secs, "{}", report.summary());
        assert!(!report.failures(&budget).is_empty());
    }

    #[test]
    fn a_stateful_hack_that_never_fades_fails_wear() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &UNFADED_STATEFUL_HACK, &care, 60, [64, 18], G9_CANVAS).unwrap();
        assert!(report.max_dwell_secs > budget.max_dwell_secs, "{}", report.summary());
        assert!(!report.failures(&budget).is_empty());
    }

    #[test]
    fn a_fading_stateful_hack_passes_wear() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &FADING_STATEFUL_HACK, &care, 120, [64, 18], G9_CANVAS).unwrap();
        assert!(report.failures(&budget).is_empty(), "{}", report.summary());
        assert!(report.average > 0.002, "{}", report.summary());
    }

    #[test]
    fn stateful_wear_is_deterministic_from_seed() {
        let Some(gpu) = gpu() else { return };
        let (care, _) = shipped();
        let a = run(&gpu, &FADING_STATEFUL_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        let b = run(&gpu, &FADING_STATEFUL_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert_eq!(a.average, b.average);
        assert_eq!(a.max_dwell_secs, b.max_dwell_secs);
        assert_eq!(a.hot_spot, b.hot_spot);
        assert_eq!(a.peak, b.peak);
    }

    #[test]
    fn an_unfaded_particle_hack_fails_wear() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &UNFADED_PARTICLE_HACK, &care, 60, [64, 18], G9_CANVAS).unwrap();
        assert!(report.max_dwell_secs > budget.max_dwell_secs, "{}", report.summary());
        assert!(!report.failures(&budget).is_empty());
    }

    #[test]
    fn a_fading_particle_hack_passes_wear() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &FADING_PARTICLE_HACK, &care, 120, [64, 18], G9_CANVAS).unwrap();
        assert!(report.failures(&budget).is_empty(), "{}", report.summary());
        assert!(report.average > 0.002, "{}", report.summary());
    }

    #[test]
    fn particle_wear_is_deterministic_from_seed() {
        let Some(gpu) = gpu() else { return };
        let (care, _) = shipped();
        let a = run(&gpu, &FADING_PARTICLE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        let b = run(&gpu, &FADING_PARTICLE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert_eq!(a.average, b.average);
        assert_eq!(a.max_dwell_secs, b.max_dwell_secs);
        assert_eq!(a.hot_spot, b.hot_spot);
        assert_eq!(a.peak, b.peak);
    }

    #[test]
    fn a_still_line_hack_fails_the_dwell_budget() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &STILL_LINE_HACK, &care, 60, [64, 18], G9_CANVAS).unwrap();
        assert!(report.max_dwell_secs > budget.max_dwell_secs, "{}", report.summary());
        assert!(!report.failures(&budget).is_empty());
    }

    #[test]
    fn a_moving_line_hack_passes_wear() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &MOVING_LINE_HACK, &care, 120, [64, 18], G9_CANVAS).unwrap();
        assert!(report.failures(&budget).is_empty(), "{}", report.summary());
        assert!(report.average > 0.002, "{}", report.summary());
    }

    #[test]
    fn line_wear_is_deterministic_from_seed() {
        let Some(gpu) = gpu() else { return };
        let (care, _) = shipped();
        let a = run(&gpu, &MOVING_LINE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        let b = run(&gpu, &MOVING_LINE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert_eq!(a.average, b.average);
        assert_eq!(a.max_dwell_secs, b.max_dwell_secs);
        assert_eq!(a.hot_spot, b.hot_spot);
        assert_eq!(a.peak, b.peak);
    }

    #[test]
    fn line_blend_modes_respect_care_limits_and_hairline_energy() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();

        let overdriven =
            run(&gpu, &OVERDRIVEN_ADD_LINE_HACK, &care, 30, [64, 18], G9_CANVAS).unwrap();
        assert!(overdriven.peak <= budget.max_drive + 1.0 / 255.0, "{}", overdriven.summary());
        assert!(overdriven.average <= budget.max_average + 0.01, "{}", overdriven.summary());

        let hairline = run(&gpu, &HAIRLINE_LINE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert!(hairline.average > 0.0005, "{}", hairline.summary());

        let mut renderer = Renderer::new(&gpu.device, &gpu.queue, care);
        assert!(renderer.prepare(&ZERO_LINES_HACK).is_err());
    }

    #[test]
    fn line_and_feedback_compose_together() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &FEEDBACK_AND_LINE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert!(report.failures(&budget).is_empty(), "{}", report.summary());
        assert!(report.average > 0.002, "{}", report.summary());
    }

    /// The limiter and the caps hold a full-white hack to the budget.
    #[test]
    fn the_care_pass_holds_white_to_the_limits() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &WHITE_HACK, &care, 30, [64, 18], G9_CANVAS).unwrap();
        assert!(report.peak <= budget.max_drive + 1.0 / 255.0, "{}", report.summary());
        assert!(report.average <= budget.max_average + 0.01, "{}", report.summary());
    }

    #[test]
    fn hue_turn_keeps_the_level() {
        // r + g + b is unchanged by the turn, so the limiter never sees it.
        let c = [0.8f32, 0.2, 0.1];
        let k = 1.0 / 3.0f32.sqrt();
        let a = 1.1f32;
        let dot = (c[0] + c[1] + c[2]) * k;
        let cross = [k * (c[2] - c[1]), k * (c[0] - c[2]), k * (c[1] - c[0])];
        let turned: Vec<f32> = (0..3)
            .map(|i| c[i] * a.cos() + cross[i] * a.sin() + k * dot * (1.0 - a.cos()))
            .collect();
        let before: f32 = c.iter().sum();
        let after: f32 = turned.iter().sum();
        assert!((before - after).abs() < 1e-5);
    }

    #[test]
    fn a_still_mesh_hack_fails_the_dwell_budget() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &STILL_MESH_HACK, &care, 60, [64, 18], G9_CANVAS).unwrap();
        assert!(report.max_dwell_secs > budget.max_dwell_secs, "{}", report.summary());
        assert!(!report.failures(&budget).is_empty());
    }

    #[test]
    fn a_moving_mesh_hack_passes_wear() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();
        let report = run(&gpu, &MOVING_MESH_HACK, &care, 120, [64, 18], G9_CANVAS).unwrap();
        assert!(report.failures(&budget).is_empty(), "{}", report.summary());
        assert!(report.average > 0.002, "{}", report.summary());
    }

    #[test]
    fn mesh_wear_is_deterministic_from_seed() {
        let Some(gpu) = gpu() else { return };
        let (care, _) = shipped();
        let a = run(&gpu, &MOVING_MESH_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        let b = run(&gpu, &MOVING_MESH_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert_eq!(a.average, b.average);
        assert_eq!(a.max_dwell_secs, b.max_dwell_secs);
        assert_eq!(a.hot_spot, b.hot_spot);
        assert_eq!(a.peak, b.peak);
    }

    #[test]
    fn mesh_depth_buffer_occludes_far_geometry_behind_near_geometry() {
        let Some(gpu) = gpu() else { return };
        let care = CareSettings {
            drive: 1.0,
            max_average: 1.0,
            white: 1.0,
            orbit_secs: None,
            hue_cycle_secs: None,
        };
        let size = [64u32, 64u32];
        let canvas = [64.0f32, 64.0f32];
        let device = &gpu.device;
        let mut renderer = Renderer::new(device, &gpu.queue, care);
        renderer.resize(canvas, size);
        renderer.reset_limiter();
        renderer.reset_state();
        renderer.prepare(&DEPTH_OCCLUSION_HACK).unwrap();

        let format = wgpu::TextureFormat::Rgba8Unorm;
        let target = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("depth_test"),
            size: wgpu::Extent3d { width: size[0], height: size[1], depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = target.create_view(&Default::default());
        let row = (size[0] * 4).div_ceil(256) * 256;
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("depth_readback"),
            size: (row * size[1]) as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let place = Placement { rect: [0.0, 0.0, canvas[0], canvas[1]], px: size };
        let frame =
            Frame { hack: &DEPTH_OCCLUSION_HACK, t: 0.0, phase: 0.0, dt: 1.0 / 60.0, seed: 0.0 };
        let mut enc = device.create_command_encoder(&Default::default());
        renderer.draw_canvas(&mut enc, &frame).unwrap();
        renderer.draw_output(&mut enc, 0, &view, format, &place, 1.0).unwrap();
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(size[1]),
                },
            },
            wgpu::Extent3d { width: size[0], height: size[1], depth_or_array_layers: 1 },
        );
        gpu.queue.submit(Some(enc.finish()));
        readback.map_async(wgpu::MapMode::Read, .., |r| r.expect("map depth readback"));
        device.poll(wgpu::PollType::Wait { submission_index: None, timeout: None }).unwrap();

        let bytes = readback.get_mapped_range(..).unwrap();
        let px_at = |x: u32, y: u32| -> [u8; 3] {
            let off = y as usize * row as usize + x as usize * 4;
            [bytes[off], bytes[off + 1], bytes[off + 2]]
        };
        let center = px_at(32, 32);
        let outer = px_at(46, 32);
        assert!(
            center[1] > 100 && center[1] > center[0].saturating_mul(3),
            "expected near green cube at center, got {center:?}"
        );
        assert!(
            outer[0] > 100 && outer[0] > outer[1].saturating_mul(3),
            "expected far red cube outside near cube, got {outer:?}"
        );
    }

    #[test]
    fn mesh_composes_with_feedback_and_lines_and_validates_bad_specs() {
        let Some(gpu) = gpu() else { return };
        let (care, budget) = shipped();

        let composed =
            run(&gpu, &FEEDBACK_MESH_AND_LINE_HACK, &care, 20, [64, 18], G9_CANVAS).unwrap();
        assert!(composed.failures(&budget).is_empty(), "{}", composed.summary());
        assert!(composed.average > 0.002, "{}", composed.summary());

        let overdriven = run(&gpu, &OVERDRIVEN_MESH_HACK, &care, 30, [64, 18], G9_CANVAS).unwrap();
        assert!(overdriven.peak <= budget.max_drive + 1.0 / 255.0, "{}", overdriven.summary());
        assert!(overdriven.average <= budget.max_average + 0.01, "{}", overdriven.summary());

        let mut renderer = Renderer::new(&gpu.device, &gpu.queue, care);
        assert!(renderer.prepare(&EMPTY_MESH_HACK).is_err());
        assert!(renderer.prepare(&ZERO_INSTANCES_MESH_HACK).is_err());
        assert!(renderer.prepare(&BAD_CUSTOM_MESH_HACK).is_err());
    }
}
