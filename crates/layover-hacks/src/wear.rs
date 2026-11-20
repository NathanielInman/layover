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
    renderer.prepare(hack)?;

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
        source: "fn hack(p: vec2<f32>, t: f32) -> vec3<f32> { let on = step(1.6, p.x) * step(p.x, 2.0) * step(0.4, p.y) * step(p.y, 0.6); return vec3<f32>(on * 0.9); }",
    };

    static WHITE_HACK: Hack = Hack {
        id: "white",
        name: "White",
        about: "Every pixel full white, changing.",
        text_heavy: false,
        hue_turn: true,
        source: "fn hack(p: vec2<f32>, t: f32) -> vec3<f32> { return vec3<f32>(0.8 + 0.2 * sin(t * 3.0 + p.x * 40.0)); }",
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
}
