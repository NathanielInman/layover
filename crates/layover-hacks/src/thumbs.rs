//! Thumbnails for the drawer: a hack rendered headless through the same
//! care pass the saver uses, so the drawer shows what the panel would. Each
//! hack gets an early frame, a settled frame and a few seconds of loop as a
//! strip of frames stacked top to bottom.
//!
//! The care pass caps every subpixel at `care.max_drive`; the thumbnails are
//! lifted by its inverse so they read on a lit drawer. Nothing here is shown
//! on the panel for long: the drawer plays a loop only under the pointer.

use crate::Hack;
use crate::gpu::Gpu;
use crate::renderer::{CareSettings, Frame, Placement, Renderer};
use anyhow::{Context, Result};
use std::path::Path;

/// Hack seconds of the early frame, the settled frame and the loop's start.
pub const EARLY_AT: f32 = 30.0;
pub const STILL_AT: f32 = 150.0;
pub const LOOP_AT: f32 = 60.0;
/// The loop: frames and their rate.
pub const LOOP_FRAMES: u32 = 32;
pub const LOOP_FPS: u32 = 8;
/// Simulation steps per second: stateful hacks need their history.
const STEP_HZ: f32 = 8.0;
/// Bump when the way thumbnails are made changes, so caches redraw.
pub const VERSION: u32 = 1;

/// One hack's thumbnails as RGBA rows.
pub struct Thumbs {
    pub size: [u32; 2],
    pub early: Vec<u8>,
    pub still: Vec<u8>,
    /// `LOOP_FRAMES` frames stacked top to bottom.
    pub strip: Vec<u8>,
}

/// What a cached thumbnail was drawn from: the hack's shader, the canvas and
/// this module's version. A different key means draw it again.
pub fn key(hack: &Hack, canvas: [f32; 2], size: [u32; 2]) -> String {
    // FNV-1a: stable across runs and releases, unlike std's hasher.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for b in bytes {
            h ^= *b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    eat(hack.id.as_bytes());
    eat(hack.source.as_bytes());
    eat(crate::renderer::shared_source_key().as_bytes());
    eat(format!("{canvas:?}{size:?}{VERSION}").as_bytes());
    format!("{h:016x}")
}

/// Renders `hack` from a fixed seed: an early frame, a settled frame and the
/// loop.
pub fn render(
    gpu: &Gpu,
    hack: &'static Hack,
    care: &CareSettings,
    size: [u32; 2],
    canvas: [f32; 2],
) -> Result<Thumbs> {
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
        label: Some("thumbs"),
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
        label: Some("thumbs readback"),
        size: (row * size[1]) as u64,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let place = Placement { rect: [0.0, 0.0, canvas[0], canvas[1]], px: size };
    let lift = 1.0 / care.drive.max(0.05);
    let frame_bytes = (size[0] * size[1] * 4) as usize;

    let dt = 1.0 / STEP_HZ;
    let loop_step = (STEP_HZ / LOOP_FPS as f32).round().max(1.0) as u32;
    let step_of = |t: f32| (t * STEP_HZ).round() as u32;
    let (early_at, still_at, loop_at) = (step_of(EARLY_AT), step_of(STILL_AT), step_of(LOOP_AT));
    let loop_end = loop_at + LOOP_FRAMES * loop_step;
    let last = still_at.max(loop_end);

    let mut out = Thumbs {
        size,
        early: Vec::new(),
        still: Vec::new(),
        strip: Vec::with_capacity(frame_bytes * LOOP_FRAMES as usize),
    };
    for step in 0..=last {
        let t = step as f32 * dt;
        let in_loop = step >= loop_at && step < loop_end && (step - loop_at) % loop_step == 0;
        let wanted = step == early_at || step == still_at || in_loop;
        let mut enc = device.create_command_encoder(&Default::default());
        renderer.draw_canvas(&mut enc, &Frame { hack, t, phase: t as f64, dt, seed: 0.37 })?;
        if !wanted {
            gpu.queue.submit(Some(enc.finish()));
            if step % 64 == 0 {
                device
                    .poll(wgpu::PollType::Wait { submission_index: None, timeout: None })
                    .context("waiting for the GPU")?;
            }
            continue;
        }
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
        readback.map_async(wgpu::MapMode::Read, .., |r| r.expect("mapping the thumbnail"));
        device
            .poll(wgpu::PollType::Wait { submission_index: None, timeout: None })
            .context("waiting for the GPU")?;
        let mut frame = Vec::with_capacity(frame_bytes);
        {
            let bytes = readback.get_mapped_range(..).context("reading back the frame")?;
            for y in 0..size[1] as usize {
                let line = &bytes[y * row as usize..y * row as usize + size[0] as usize * 4];
                for px in line.as_chunks::<4>().0 {
                    for c in &px[..3] {
                        frame.push(lifted(*c, lift));
                    }
                    frame.push(255);
                }
            }
        }
        readback.unmap();
        if step == early_at {
            out.early = frame.clone();
        }
        if step == still_at {
            out.still = frame.clone();
        }
        if in_loop {
            out.strip.extend_from_slice(&frame);
        }
    }
    Ok(out)
}

/// A channel scaled back up by `lift`, saturating.
fn lifted(c: u8, lift: f32) -> u8 {
    (c as f32 * lift).round().min(255.0) as u8
}

/// Writes RGBA rows as a PNG, `w` wide.
pub fn write_png(path: &Path, rgba: &[u8], w: u32) -> Result<()> {
    let h = (rgba.len() / (w as usize * 4)) as u32;
    let tmp = path.with_extension("png.tmp");
    {
        let file =
            std::fs::File::create(&tmp).with_context(|| format!("creating {}", tmp.display()))?;
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::High);
        let mut writer = enc.write_header()?;
        writer.write_image_data(rgba)?;
    }
    std::fs::rename(&tmp, path).with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_change_with_the_shader_and_the_canvas() {
        let a = crate::find("starfield").unwrap();
        let b = crate::find("night-mail").unwrap();
        let canvas = crate::wear::G9_CANVAS;
        assert_eq!(key(a, canvas, [384, 108]), key(a, canvas, [384, 108]));
        assert_ne!(key(a, canvas, [384, 108]), key(b, canvas, [384, 108]));
        assert_ne!(key(a, canvas, [384, 108]), key(a, [2560.0, 1440.0], [384, 216]));
    }

    #[test]
    fn a_loop_and_two_stills_come_out_lifted() {
        if std::env::var_os("LAYOVER_SKIP_GPU_TESTS").is_some() {
            return;
        }
        let gpu = Gpu::headless().expect("thumbnails need a Vulkan adapter (CI uses lavapipe)");
        let care = CareSettings::from_config(&layover_core::config::Care::default());
        let t =
            render(&gpu, crate::find("frost-aurora").unwrap(), &care, [64, 18], [5120.0, 1440.0])
                .unwrap();
        let frame = 64 * 18 * 4;
        assert_eq!(t.early.len(), frame);
        assert_eq!(t.still.len(), frame);
        assert_eq!(t.strip.len(), frame * LOOP_FRAMES as usize);
        assert!(t.still.as_chunks::<4>().0.iter().any(|p| p[..3] != [0, 0, 0]), "something is lit");
        let frames: Vec<_> = t.strip.chunks_exact(frame).collect();
        assert_ne!(frames[0], frames[frames.len() - 1], "the loop moves");
    }

    #[test]
    fn the_lift_undoes_max_drive() {
        assert_eq!(lifted(153, 1.0 / 0.6), 255);
        assert_eq!(lifted(60, 1.0 / 0.6), 100);
        assert_eq!(lifted(250, 2.0), 255);
    }
}
