//! The renderer: one hack pass over the whole canvas, the limiter, and a
//! care pass per output. Rule one lives in `care.wgsl` and `limiter.wgsl`;
//! this file only feeds them.

use crate::Hack;
use crate::board::BoardData;
use anyhow::{Result, anyhow};
use bytemuck::{Pod, Zeroable};
use layover_core::config::Care;
use std::collections::HashMap;

/// Care values the renderer applies, from `[care]`.
#[derive(Clone, Debug)]
pub struct CareSettings {
    pub drive: f32,
    pub max_average: f32,
    pub white: f32,
    /// Seconds per orbit; `None` when off.
    pub orbit_secs: Option<f64>,
    /// Seconds per turn of the hue wheel; `None` when off.
    pub hue_cycle_secs: Option<f64>,
}

impl CareSettings {
    pub fn from_config(c: &Care) -> Self {
        CareSettings {
            drive: c.max_drive,
            max_average: c.max_average,
            white: c.max_white,
            orbit_secs: c.orbit.duration().map(|d| d.as_secs_f64()),
            hue_cycle_secs: c.hue_cycle.duration().map(|d| d.as_secs_f64()),
        }
    }

    /// How far the frame orbits, in canvas pixels, for a canvas this tall.
    fn orbit_radius(canvas_h: f32) -> f32 {
        (canvas_h * 0.008).max(4.0)
    }

    /// The orbit offset at `phase` seconds: a slow figure eight.
    pub fn orbit(&self, phase: f64, canvas_h: f32) -> [f32; 2] {
        match self.orbit_secs {
            Some(period) => {
                let a = std::f64::consts::TAU * (phase / period);
                let r = Self::orbit_radius(canvas_h) as f64;
                [(r * a.sin()) as f32, (r * 0.6 * (2.0 * a + 1.0).sin()) as f32]
            }
            None => [0.0, 0.0],
        }
    }

    /// The hue angle at `phase` seconds, in radians.
    pub fn hue(&self, phase: f64) -> f32 {
        match self.hue_cycle_secs {
            Some(period) => (std::f64::consts::TAU * (phase / period).fract()) as f32,
            None => 0.0,
        }
    }
}

/// One frame's inputs.
#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub hack: &'static Hack,
    /// Hack time in seconds.
    pub t: f32,
    /// Care time in seconds (hue and orbit). The saver uses wall-clock time
    /// so each run starts somewhere new on the wheel.
    pub phase: f64,
    /// Seconds since the last frame, for the limiter.
    pub dt: f32,
    /// Per-run variation, 0..1.
    pub seed: f32,
}

/// Where an output sits on the canvas.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    /// x, y, width, height in canvas (logical) pixels.
    pub rect: [f32; 4],
    /// The output's buffer size in physical pixels.
    pub px: [u32; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Globals {
    canvas: [f32; 2],
    target_size: [f32; 2],
    orbit: [f32; 2],
    time: f32,
    seed: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Limit {
    drive: f32,
    max_average: f32,
    dt: f32,
    _pad: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct CareU {
    rect: [f32; 4],
    canvas: [f32; 2],
    px_to_canvas: [f32; 2],
    drive: f32,
    white: f32,
    hue: f32,
    hue_on: f32,
    fade: f32,
    _pad: [f32; 3],
}

const PRELUDE: &str = include_str!("hacks/prelude.wgsl");

/// The board binding, for hacks with `board: true`.
const BOARD_BINDING: &str = r#"
struct Board {
    cols: u32,
    rows: u32,
    shown: u32,
    pad: u32,
    changed: array<vec4<f32>, 3>,
    cells: array<u32, CELLS>,
};

@group(1) @binding(0) var<storage, read> board: Board;

fn board_changed(i: u32) -> f32 {
    return board.changed[i / 4u][i % 4u];
}
"#;
const HACK_MAIN: &str = r#"
@fragment
fn fs_hack(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let cp = pos.xy * (g.canvas / g.target_size) + g.orbit;
    let p = vec2<f32>(cp.x / g.canvas.y, 1.0 - cp.y / g.canvas.y);
    let c = hack(p, g.time);
    return vec4<f32>(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
"#;

const OFFSCREEN_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

struct Offscreen {
    view: wgpu::TextureView,
    size: [u32; 2],
    limiter_bg: wgpu::BindGroup,
}

struct Slot {
    uniform: wgpu::Buffer,
    bind: wgpu::BindGroup,
}

pub struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    care: CareSettings,
    canvas: [f32; 2],
    offscreen: Option<Offscreen>,
    hack_layout: wgpu::PipelineLayout,
    hack_bg: wgpu::BindGroup,
    /// Hacks that read the Departure Board's cells get a second group.
    board_layout: wgpu::PipelineLayout,
    board_buf: wgpu::Buffer,
    board_bg: wgpu::BindGroup,
    /// Cheap mode dims everything by this (1 otherwise).
    dim: f32,
    hack_pipes: HashMap<&'static str, wgpu::RenderPipeline>,
    globals: wgpu::Buffer,
    limit: wgpu::Buffer,
    gain: wgpu::Buffer,
    limiter_bgl: wgpu::BindGroupLayout,
    limiter: wgpu::ComputePipeline,
    care_module: wgpu::ShaderModule,
    care_bgl: wgpu::BindGroupLayout,
    care_layout: wgpu::PipelineLayout,
    care_pipes: HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>,
    sampler: wgpu::Sampler,
    slots: HashMap<usize, Slot>,
    hue: f32,
    hue_on: bool,
}

fn uniform_entry(binding: u32, vis: wgpu::ShaderStages) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: vis,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn texture_entry(binding: u32, vis: wgpu::ShaderStages) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: vis,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}

fn storage_entry(
    binding: u32,
    vis: wgpu::ShaderStages,
    read_only: bool,
) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: vis,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn buffer(
    device: &wgpu::Device,
    label: &str,
    size: u64,
    usage: wgpu::BufferUsages,
) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some(label),
        size,
        usage,
        mapped_at_creation: false,
    })
}

impl Renderer {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue, care: CareSettings) -> Renderer {
        let frag = wgpu::ShaderStages::FRAGMENT;
        let comp = wgpu::ShaderStages::COMPUTE;
        let uni = wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST;

        let globals = buffer(device, "globals", size_of::<Globals>() as u64, uni);
        let hack_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("hack"),
            entries: &[uniform_entry(0, frag)],
        });
        let hack_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("hack"),
            layout: &hack_bgl,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: globals.as_entire_binding() }],
        });
        let hack_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("hack"),
            bind_group_layouts: &[Some(&hack_bgl)],
            immediate_size: 0,
        });
        let board_buf = buffer(
            device,
            "board",
            size_of::<BoardData>() as u64,
            wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        );
        queue.write_buffer(
            &board_buf,
            0,
            bytemuck::bytes_of(&BoardData::compose(&[], &[], "", &[])),
        );
        let board_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("board"),
            entries: &[storage_entry(0, frag, true)],
        });
        let board_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("board"),
            layout: &board_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: board_buf.as_entire_binding(),
            }],
        });
        let board_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("board hack"),
            bind_group_layouts: &[Some(&hack_bgl), Some(&board_bgl)],
            immediate_size: 0,
        });

        let limit = buffer(device, "limit", size_of::<Limit>() as u64, uni);
        let gain = buffer(
            device,
            "gain",
            8,
            wgpu::BufferUsages::STORAGE
                | wgpu::BufferUsages::COPY_DST
                | wgpu::BufferUsages::COPY_SRC,
        );
        let limiter_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("limiter"),
            entries: &[
                texture_entry(0, comp),
                uniform_entry(1, comp),
                storage_entry(2, comp, false),
            ],
        });
        let limiter_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("limiter"),
            source: wgpu::ShaderSource::Wgsl(include_str!("limiter.wgsl").into()),
        });
        let limiter_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("limiter"),
            bind_group_layouts: &[Some(&limiter_bgl)],
            immediate_size: 0,
        });
        let limiter = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("limiter"),
            layout: Some(&limiter_layout),
            module: &limiter_module,
            entry_point: Some("measure"),
            compilation_options: Default::default(),
            cache: None,
        });

        let care_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("care"),
            source: wgpu::ShaderSource::Wgsl(include_str!("care.wgsl").into()),
        });
        let care_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("care"),
            entries: &[
                texture_entry(0, frag),
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: frag,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                uniform_entry(2, frag),
                storage_entry(3, frag, true),
            ],
        });
        let care_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("care"),
            bind_group_layouts: &[Some(&care_bgl)],
            immediate_size: 0,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("care"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        Renderer {
            device: device.clone(),
            queue: queue.clone(),
            care,
            canvas: [1.0, 1.0],
            offscreen: None,
            hack_layout,
            hack_bg,
            board_layout,
            board_buf,
            board_bg,
            dim: 1.0,
            hack_pipes: HashMap::new(),
            globals,
            limit,
            gain,
            limiter_bgl,
            limiter,
            care_module,
            care_bgl,
            care_layout,
            care_pipes: HashMap::new(),
            sampler,
            slots: HashMap::new(),
            hue: 0.0,
            hue_on: true,
        }
    }

    /// Set the canvas (logical pixels, the bounding box of every output) and
    /// the size the hack pass draws at.
    pub fn resize(&mut self, canvas: [f32; 2], offscreen: [u32; 2]) {
        let offscreen = [offscreen[0].max(1), offscreen[1].max(1)];
        if self.canvas == canvas && self.offscreen.as_ref().is_some_and(|o| o.size == offscreen) {
            return;
        }
        self.canvas = canvas;
        let tex = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("hack"),
            size: wgpu::Extent3d {
                width: offscreen[0],
                height: offscreen[1],
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: OFFSCREEN_FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let view = tex.create_view(&Default::default());
        let limiter_bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("limiter"),
            layout: &self.limiter_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry { binding: 1, resource: self.limit.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: self.gain.as_entire_binding() },
            ],
        });
        self.offscreen = Some(Offscreen { view, size: offscreen, limiter_bg });
        self.slots.clear();
    }

    /// Compile a hack ahead of time. A shader error comes back as an error
    /// instead of taking the process down.
    pub fn prepare(&mut self, hack: &'static Hack) -> Result<()> {
        if self.hack_pipes.contains_key(hack.id) {
            return Ok(());
        }
        let scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let board = if hack.board {
            format!(
                "{}\n{}",
                BOARD_BINDING.replace("CELLS", &crate::board::CELLS.to_string()),
                crate::board::font_wgsl()
            )
        } else {
            String::new()
        };
        let source = format!("{PRELUDE}\n{board}\n{}\n{HACK_MAIN}", hack.source);
        let module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(hack.id),
            source: wgpu::ShaderSource::Wgsl(source.into()),
        });
        let pipe = self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(hack.id),
            layout: Some(if hack.board { &self.board_layout } else { &self.hack_layout }),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_hack"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: OFFSCREEN_FORMAT,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        if let Some(err) = pollster::block_on(scope.pop()) {
            return Err(anyhow!("hack {} does not compile: {err}", hack.id));
        }
        self.hack_pipes.insert(hack.id, pipe);
        Ok(())
    }

    /// Draw the hack over the whole canvas and run the limiter.
    pub fn draw_canvas(&mut self, encoder: &mut wgpu::CommandEncoder, frame: &Frame) -> Result<()> {
        self.prepare(frame.hack)?;
        let off = self.offscreen.as_ref().ok_or_else(|| anyhow!("resize before drawing"))?;
        let globals = Globals {
            canvas: self.canvas,
            target_size: [off.size[0] as f32, off.size[1] as f32],
            orbit: self.care.orbit(frame.phase, self.canvas[1]),
            time: frame.t,
            seed: frame.seed,
        };
        self.queue.write_buffer(&self.globals, 0, bytemuck::bytes_of(&globals));
        let limit = Limit {
            drive: self.care.drive * self.dim,
            max_average: self.care.max_average,
            dt: frame.dt.max(0.0),
            _pad: 0.0,
        };
        self.queue.write_buffer(&self.limit, 0, bytemuck::bytes_of(&limit));
        self.hue = self.care.hue(frame.phase);
        self.hue_on = frame.hack.hue_turn;

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("hack"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &off.view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.hack_pipes[frame.hack.id]);
            pass.set_bind_group(0, &self.hack_bg, &[]);
            if frame.hack.board {
                pass.set_bind_group(1, &self.board_bg, &[]);
            }
            pass.draw(0..3, 0..1);
        }
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("limiter"),
                timestamp_writes: None,
            });
            pass.set_pipeline(&self.limiter);
            pass.set_bind_group(0, &off.limiter_bg, &[]);
            pass.dispatch_workgroups(1, 1, 1);
        }
        Ok(())
    }

    /// Forget the limiter's gain, for a new run.
    /// Hand the Departure Board its cells.
    pub fn set_board(&self, data: &BoardData) {
        self.queue.write_buffer(&self.board_buf, 0, bytemuck::bytes_of(data));
    }

    /// Dim every frame by `dim` (cheap mode), 1 for full drive.
    pub fn set_dim(&mut self, dim: f32) {
        self.dim = dim.clamp(0.1, 1.0);
    }

    pub fn reset_limiter(&self) {
        self.queue.write_buffer(&self.gain, 0, bytemuck::bytes_of(&[0.0f32, 0.0f32]));
    }

    fn care_pipe(&mut self, format: wgpu::TextureFormat) -> &wgpu::RenderPipeline {
        self.care_pipes.entry(format).or_insert_with(|| {
            self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("care"),
                layout: Some(&self.care_layout),
                vertex: wgpu::VertexState {
                    module: &self.care_module,
                    entry_point: Some("vs"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &self.care_module,
                    entry_point: Some("fs"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview_mask: None,
                cache: None,
            })
        })
    }

    /// Draw one output's part of the canvas through the care pass. `slot`
    /// identifies the output so each keeps its own uniforms.
    pub fn draw_output(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        slot: usize,
        target: &wgpu::TextureView,
        format: wgpu::TextureFormat,
        place: &Placement,
        fade: f32,
    ) -> Result<()> {
        self.care_pipe(format);
        let off = self.offscreen.as_ref().ok_or_else(|| anyhow!("resize before drawing"))?;
        if !self.slots.contains_key(&slot) {
            let uniform = buffer(
                &self.device,
                "care",
                size_of::<CareU>() as u64,
                wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            );
            let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("care"),
                layout: &self.care_bgl,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(&off.view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::Sampler(&self.sampler),
                    },
                    wgpu::BindGroupEntry { binding: 2, resource: uniform.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 3, resource: self.gain.as_entire_binding() },
                ],
            });
            self.slots.insert(slot, Slot { uniform, bind });
        }
        let u = CareU {
            rect: place.rect,
            canvas: self.canvas,
            px_to_canvas: [
                place.rect[2] / place.px[0].max(1) as f32,
                place.rect[3] / place.px[1].max(1) as f32,
            ],
            drive: self.care.drive * self.dim,
            white: self.care.white,
            hue: self.hue,
            hue_on: if self.hue_on { 1.0 } else { 0.0 },
            fade: fade.clamp(0.0, 1.0),
            _pad: [0.0; 3],
        };
        let s = &self.slots[&slot];
        self.queue.write_buffer(&s.uniform, 0, bytemuck::bytes_of(&u));
        let pipe = &self.care_pipes[&format];
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("care"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(pipe);
        pass.set_bind_group(0, &s.bind, &[]);
        pass.draw(0..3, 0..1);
        Ok(())
    }

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }
}
