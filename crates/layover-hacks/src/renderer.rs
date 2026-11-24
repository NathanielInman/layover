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
    dt: f32,
    fade: f32,
    frame: f32,
    _pad: f32,
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
    aa_on: f32,
    _pad: [f32; 2],
}

const PRELUDE: &str = include_str!("hacks/prelude.wgsl");
const RAYMARCH: &str = include_str!("hacks/raymarch.wgsl");
const FEEDBACK: &str = include_str!("hacks/feedback.wgsl");
const PARTICLES: &str = include_str!("hacks/particles.wgsl");

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
const STEP_MAIN: &str = r#"
@fragment
fn fs_step(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy / g.target_size;
    let p = vec2<f32>(uv.x * aspect(), 1.0 - uv.y);
    let s = step_state(uv, p, g.time);
    return clamp(s, vec4<f32>(-100.0), vec4<f32>(100.0));
}
"#;
const PARTICLE_MAIN: &str = r#"
@compute @workgroup_size(64)
fn cs_particles(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= arrayLength(&particles)) {
        return;
    }
    step_particle(gid.x, g.time);
}
"#;
const RESOLVE_MAIN: &str = r#"
@compute @workgroup_size(8, 8)
fn cs_resolve(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(state_out);
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }
    let base = (gid.y * dims.x + gid.x) * 4u;
    let splat = vec4<f32>(
        f32(atomicExchange(&splat_buf[base + 0u], 0u)),
        f32(atomicExchange(&splat_buf[base + 1u], 0u)),
        f32(atomicExchange(&splat_buf[base + 2u], 0u)),
        f32(atomicExchange(&splat_buf[base + 3u], 0u)),
    ) / SPLAT_SCALE;
    let uv = (vec2<f32>(gid.xy) + 0.5) / vec2<f32>(dims);
    let p = vec2<f32>(uv.x * aspect(), 1.0 - uv.y);
    let next_s = resolve_state(uv, p, g.time, splat);
    let finite_s = select(vec4<f32>(0.0), next_s, next_s == next_s);
    let safe = clamp(finite_s, vec4<f32>(-1000.0), vec4<f32>(1000.0));
    textureStore(state_out, vec2<i32>(gid.xy), safe);
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
const STATE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const MAX_SUBSTEPS: u32 = 32;
const PARTICLE_BYTES: u64 = 48;

struct Offscreen {
    view: wgpu::TextureView,
    size: [u32; 2],
    limiter_bg: wgpu::BindGroup,
}

struct StateTextures {
    views: [wgpu::TextureView; 2],
    clamp_bgs: [wgpu::BindGroup; 2],
    repeat_bgs: [wgpu::BindGroup; 2],
    resolve_out_bgs: [wgpu::BindGroup; 2],
    size: [u32; 2],
}

struct ParticleBuffers {
    particles: wgpu::Buffer,
    splat: wgpu::Buffer,
    bg: wgpu::BindGroup,
    count: u32,
    state_size: [u32; 2],
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
    /// Tier S feedback state ping-pong resources.
    feedback_bgl: wgpu::BindGroupLayout,
    feedback_hack_layout: wgpu::PipelineLayout,
    step_layout: wgpu::PipelineLayout,
    step_globals: wgpu::Buffer,
    step_stride: usize,
    step_bg: wgpu::BindGroup,
    step_pipes: HashMap<&'static str, wgpu::RenderPipeline>,
    /// Tier P compute particle & splat resolve resources.
    particle_bgl: wgpu::BindGroupLayout,
    resolve_out_bgl: wgpu::BindGroupLayout,
    particle_step_layout: wgpu::PipelineLayout,
    particle_resolve_layout: wgpu::PipelineLayout,
    particle_pipes: HashMap<&'static str, wgpu::ComputePipeline>,
    resolve_pipes: HashMap<&'static str, wgpu::ComputePipeline>,
    particles: Option<ParticleBuffers>,
    state_clamp_sampler: wgpu::Sampler,
    state_repeat_sampler: wgpu::Sampler,
    state: Option<StateTextures>,
    state_hack: Option<&'static str>,
    state_front: usize,
    state_frame: u64,
    state_needs_clear: bool,
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
    antialias: bool,
    aa_on: bool,
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

        let globals_size = wgpu::BufferSize::new(size_of::<Globals>() as u64);
        let align = device.limits().min_uniform_buffer_offset_alignment.max(1) as usize;
        let step_stride = size_of::<Globals>().div_ceil(align) * align;
        let step_globals =
            buffer(device, "step_globals", (step_stride * MAX_SUBSTEPS as usize) as u64, uni);
        let frag_comp = frag | comp;
        let step_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("step"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: frag_comp,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: true,
                    min_binding_size: globals_size,
                },
                count: None,
            }],
        });
        let step_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("step"),
            layout: &step_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &step_globals,
                    offset: 0,
                    size: globals_size,
                }),
            }],
        });
        let feedback_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("feedback"),
            entries: &[
                texture_entry(0, frag_comp),
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: frag_comp,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let feedback_hack_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("feedback hack"),
            bind_group_layouts: &[Some(&hack_bgl), Some(&feedback_bgl)],
            immediate_size: 0,
        });
        let step_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("step"),
            bind_group_layouts: &[Some(&step_bgl), Some(&feedback_bgl)],
            immediate_size: 0,
        });
        let particle_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("particles"),
            entries: &[storage_entry(0, comp, false), storage_entry(1, comp, false)],
        });
        let resolve_out_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("resolve_out"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: comp,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: STATE_FORMAT,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            }],
        });
        let particle_step_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("particle step"),
            bind_group_layouts: &[Some(&step_bgl), Some(&feedback_bgl), Some(&particle_bgl)],
            immediate_size: 0,
        });
        let particle_resolve_layout =
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("particle resolve"),
                bind_group_layouts: &[
                    Some(&step_bgl),
                    Some(&feedback_bgl),
                    Some(&particle_bgl),
                    Some(&resolve_out_bgl),
                ],
                immediate_size: 0,
            });
        let make_state_sampler = |label, mode| {
            device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some(label),
                address_mode_u: mode,
                address_mode_v: mode,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            })
        };
        let state_clamp_sampler = make_state_sampler("state clamp", wgpu::AddressMode::ClampToEdge);
        let state_repeat_sampler = make_state_sampler("state repeat", wgpu::AddressMode::Repeat);

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
            feedback_bgl,
            feedback_hack_layout,
            step_layout,
            step_globals,
            step_stride,
            step_bg,
            step_pipes: HashMap::new(),
            particle_bgl,
            resolve_out_bgl,
            particle_step_layout,
            particle_resolve_layout,
            particle_pipes: HashMap::new(),
            resolve_pipes: HashMap::new(),
            particles: None,
            state_clamp_sampler,
            state_repeat_sampler,
            state: None,
            state_hack: None,
            state_front: 0,
            state_frame: 0,
            state_needs_clear: true,
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
            antialias: true,
            aa_on: true,
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

    fn build_pipeline(
        &self,
        label: &str,
        layout: &wgpu::PipelineLayout,
        module: &wgpu::ShaderModule,
        entry: &str,
        format: wgpu::TextureFormat,
    ) -> wgpu::RenderPipeline {
        self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(label),
            layout: Some(layout),
            vertex: wgpu::VertexState {
                module,
                entry_point: Some("vs"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module,
                entry_point: Some(entry),
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
    }

    fn ensure_state(&mut self, size: [u32; 2]) -> bool {
        let size = [size[0].max(1), size[1].max(1)];
        if self.state.as_ref().is_some_and(|s| s.size == size) {
            return false;
        }
        let make_tex = |label| {
            let tex = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: size[0], height: size[1], depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: STATE_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING
                    | wgpu::TextureUsages::STORAGE_BINDING,
                view_formats: &[],
            });
            tex.create_view(&Default::default())
        };
        let views = [make_tex("state 0"), make_tex("state 1")];
        let make_bg = |view: &wgpu::TextureView, sampler: &wgpu::Sampler| {
            self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("feedback"),
                layout: &self.feedback_bgl,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::Sampler(sampler),
                    },
                ],
            })
        };
        let clamp_bgs = [
            make_bg(&views[0], &self.state_clamp_sampler),
            make_bg(&views[1], &self.state_clamp_sampler),
        ];
        let repeat_bgs = [
            make_bg(&views[0], &self.state_repeat_sampler),
            make_bg(&views[1], &self.state_repeat_sampler),
        ];
        let make_out_bg = |view: &wgpu::TextureView| {
            self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("resolve_out"),
                layout: &self.resolve_out_bgl,
                entries: &[wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(view),
                }],
            })
        };
        let resolve_out_bgs = [make_out_bg(&views[0]), make_out_bg(&views[1])];
        self.state = Some(StateTextures { views, clamp_bgs, repeat_bgs, resolve_out_bgs, size });
        true
    }

    fn ensure_particles(&mut self, count: u32, state_size: [u32; 2]) -> bool {
        let count = count.max(1);
        let state_size = [state_size[0].max(1), state_size[1].max(1)];
        if self.particles.as_ref().is_some_and(|p| p.count == count && p.state_size == state_size) {
            return false;
        }
        let storage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST;
        let particles = buffer(&self.device, "particles", count as u64 * PARTICLE_BYTES, storage);
        let splat_bytes = state_size[0] as u64 * state_size[1] as u64 * 16;
        let splat = buffer(&self.device, "splat", splat_bytes, storage);
        let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("particles"),
            layout: &self.particle_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: particles.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: splat.as_entire_binding() },
            ],
        });
        self.particles = Some(ParticleBuffers { particles, splat, bg, count, state_size });
        true
    }

    fn build_compute_pipeline(
        &self,
        label: &str,
        layout: &wgpu::PipelineLayout,
        module: &wgpu::ShaderModule,
        entry: &str,
    ) -> wgpu::ComputePipeline {
        self.device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some(label),
            layout: Some(layout),
            module,
            entry_point: Some(entry),
            compilation_options: Default::default(),
            cache: None,
        })
    }

    /// Compile a hack ahead of time. A shader error comes back as an error
    /// instead of taking the process down.
    pub fn prepare(&mut self, hack: &'static Hack) -> Result<()> {
        if self.hack_pipes.contains_key(hack.id) {
            return Ok(());
        }
        if hack.board && (hack.feedback.is_some() || hack.particles.is_some()) {
            return Err(anyhow!("hack {} cannot mix board with feedback or particles", hack.id));
        }
        if hack.particles.is_some() && hack.feedback.is_none() {
            return Err(anyhow!("hack {} uses particles without feedback", hack.id));
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
        let raymarch = if hack.raymarch { RAYMARCH } else { "" };
        let feedback = if hack.feedback.is_some() { FEEDBACK } else { "" };
        let particles = if hack.particles.is_some() { PARTICLES } else { "" };
        let step_main = if hack.particles.is_some() {
            format!("{PARTICLE_MAIN}\n{RESOLVE_MAIN}")
        } else if hack.feedback.is_some() {
            STEP_MAIN.to_string()
        } else {
            String::new()
        };
        let source = format!(
            "{PRELUDE}\n{raymarch}\n{board}\n{feedback}\n{particles}\n{}\n{step_main}\n{HACK_MAIN}",
            hack.source
        );
        let module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(hack.id),
            source: wgpu::ShaderSource::Wgsl(source.into()),
        });
        let (step_pipe, particle_pipe, resolve_pipe) = if hack.particles.is_some() {
            (
                None,
                Some(self.build_compute_pipeline(
                    hack.id,
                    &self.particle_step_layout,
                    &module,
                    "cs_particles",
                )),
                Some(self.build_compute_pipeline(
                    hack.id,
                    &self.particle_resolve_layout,
                    &module,
                    "cs_resolve",
                )),
            )
        } else {
            (
                hack.feedback.map(|_| {
                    self.build_pipeline(
                        hack.id,
                        &self.step_layout,
                        &module,
                        "fs_step",
                        STATE_FORMAT,
                    )
                }),
                None,
                None,
            )
        };
        let hack_layout = if hack.board {
            &self.board_layout
        } else if hack.feedback.is_some() {
            &self.feedback_hack_layout
        } else {
            &self.hack_layout
        };
        let pipe = self.build_pipeline(hack.id, hack_layout, &module, "fs_hack", OFFSCREEN_FORMAT);
        if let Some(err) = pollster::block_on(scope.pop()) {
            return Err(anyhow!("hack {} does not compile: {err}", hack.id));
        }
        if let Some(step_pipe) = step_pipe {
            self.step_pipes.insert(hack.id, step_pipe);
        }
        if let Some(particle_pipe) = particle_pipe {
            self.particle_pipes.insert(hack.id, particle_pipe);
        }
        if let Some(resolve_pipe) = resolve_pipe {
            self.resolve_pipes.insert(hack.id, resolve_pipe);
        }
        self.hack_pipes.insert(hack.id, pipe);
        Ok(())
    }

    /// Draw the hack over the whole canvas and run the limiter.
    pub fn draw_canvas(&mut self, encoder: &mut wgpu::CommandEncoder, frame: &Frame) -> Result<()> {
        self.prepare(frame.hack)?;
        let off_size =
            self.offscreen.as_ref().ok_or_else(|| anyhow!("resize before drawing"))?.size;

        if let Some(fb) = frame.hack.feedback {
            let state_size = match fb.max_height {
                Some(max_h) if off_size[1] > max_h => {
                    let h = max_h.max(1);
                    let w = ((h as f32) * (self.canvas[0] / self.canvas[1].max(1.0)))
                        .round()
                        .max(1.0) as u32;
                    [w, h]
                }
                _ => off_size,
            };
            let recreated = self.ensure_state(state_size);
            let particles_recreated =
                frame.hack.particles.is_some_and(|pt| self.ensure_particles(pt.count, state_size));
            if recreated || particles_recreated || self.state_hack != Some(frame.hack.id) {
                self.state_hack = Some(frame.hack.id);
                self.state_needs_clear = true;
                self.state_front = 0;
                self.state_frame = 0;
            }
            let state = self.state.as_ref().expect("state is ready");
            if self.state_needs_clear {
                {
                    let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("state clear"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &state.views[0],
                            depth_slice: None,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                        multiview_mask: None,
                    });
                }
                if frame.hack.particles.is_some() {
                    let pbuf = self.particles.as_ref().expect("particles are ready");
                    encoder.clear_buffer(&pbuf.particles, 0, None);
                    encoder.clear_buffer(&pbuf.splat, 0, None);
                }
                self.state_needs_clear = false;
                self.state_front = 0;
                self.state_frame = 0;
            }

            let dt = frame.dt.max(1e-4);
            let max_steps = fb.max_steps.clamp(1, MAX_SUBSTEPS);
            let steps = (dt * fb.step_hz).round().clamp(1.0, max_steps as f32) as u32;
            let step_dt = dt / steps as f32;
            let fade = if fb.fade_secs > 0.0 { (-step_dt / fb.fade_secs).exp() } else { 1.0 };

            let mut buf = vec![0u8; steps as usize * self.step_stride];
            for i in 0..steps {
                let g = Globals {
                    canvas: self.canvas,
                    target_size: [state.size[0] as f32, state.size[1] as f32],
                    orbit: [0.0, 0.0],
                    time: frame.t + step_dt * i as f32,
                    seed: frame.seed,
                    dt: step_dt,
                    fade,
                    frame: (self.state_frame + i as u64) as f32,
                    _pad: 0.0,
                };
                let start = i as usize * self.step_stride;
                buf[start..start + size_of::<Globals>()].copy_from_slice(bytemuck::bytes_of(&g));
            }
            self.queue.write_buffer(&self.step_globals, 0, &buf);

            if let Some(pt) = frame.hack.particles {
                let pbuf = self.particles.as_ref().expect("particles are ready");
                let particle_pipe = &self.particle_pipes[frame.hack.id];
                let resolve_pipe = &self.resolve_pipes[frame.hack.id];
                let p_groups = pt.count.max(1).div_ceil(64);
                let r_groups = [state.size[0].div_ceil(8), state.size[1].div_ceil(8)];
                for i in 0..steps {
                    let src = self.state_front;
                    let dst = 1 - src;
                    let fb_bg =
                        if fb.wrap { &state.repeat_bgs[src] } else { &state.clamp_bgs[src] };
                    let dyn_off = i * self.step_stride as u32;
                    {
                        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                            label: Some("particles"),
                            timestamp_writes: None,
                        });
                        pass.set_pipeline(particle_pipe);
                        pass.set_bind_group(0, &self.step_bg, &[dyn_off]);
                        pass.set_bind_group(1, fb_bg, &[]);
                        pass.set_bind_group(2, &pbuf.bg, &[]);
                        pass.dispatch_workgroups(p_groups, 1, 1);
                    }
                    {
                        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                            label: Some("resolve"),
                            timestamp_writes: None,
                        });
                        pass.set_pipeline(resolve_pipe);
                        pass.set_bind_group(0, &self.step_bg, &[dyn_off]);
                        pass.set_bind_group(1, fb_bg, &[]);
                        pass.set_bind_group(2, &pbuf.bg, &[]);
                        pass.set_bind_group(3, &state.resolve_out_bgs[dst], &[]);
                        pass.dispatch_workgroups(r_groups[0], r_groups[1], 1);
                    }
                    self.state_front = dst;
                }
            } else {
                let step_pipe = &self.step_pipes[frame.hack.id];
                for i in 0..steps {
                    let src = self.state_front;
                    let dst = 1 - src;
                    let fb_bg =
                        if fb.wrap { &state.repeat_bgs[src] } else { &state.clamp_bgs[src] };
                    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("state step"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &state.views[dst],
                            depth_slice: None,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                        multiview_mask: None,
                    });
                    pass.set_pipeline(step_pipe);
                    pass.set_bind_group(0, &self.step_bg, &[i * self.step_stride as u32]);
                    pass.set_bind_group(1, fb_bg, &[]);
                    pass.draw(0..3, 0..1);
                    self.state_front = dst;
                }
            }
            self.state_frame += steps as u64;
        } else {
            self.state_hack = None;
        }

        let off = self.offscreen.as_ref().expect("offscreen is ready");
        let globals = Globals {
            canvas: self.canvas,
            target_size: [off.size[0] as f32, off.size[1] as f32],
            orbit: self.care.orbit(frame.phase, self.canvas[1]),
            time: frame.t,
            seed: frame.seed,
            dt: frame.dt.max(0.0),
            fade: 1.0,
            frame: self.state_frame as f32,
            _pad: 0.0,
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
        self.aa_on = self.antialias && !frame.hack.text_heavy;

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
            } else if let Some(fb) = frame.hack.feedback {
                let state = self.state.as_ref().expect("state is ready");
                let fb_bg = if fb.wrap {
                    &state.repeat_bgs[self.state_front]
                } else {
                    &state.clamp_bgs[self.state_front]
                };
                pass.set_bind_group(1, fb_bg, &[]);
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

    /// Smooth stair-steps in the care pass (skipped on text-heavy hacks).
    pub fn set_antialias(&mut self, on: bool) {
        self.antialias = on;
    }

    pub fn reset_limiter(&self) {
        self.queue.write_buffer(&self.gain, 0, bytemuck::bytes_of(&[0.0f32, 0.0f32]));
    }

    /// Forget ping-pong feedback state, for a new run.
    pub fn reset_state(&mut self) {
        self.state_hack = None;
        self.state_front = 0;
        self.state_frame = 0;
        self.state_needs_clear = true;
    }

    fn care_pipe(&mut self, format: wgpu::TextureFormat) -> &wgpu::RenderPipeline {
        if !self.care_pipes.contains_key(&format) {
            let pipe =
                self.build_pipeline("care", &self.care_layout, &self.care_module, "fs", format);
            self.care_pipes.insert(format, pipe);
        }
        &self.care_pipes[&format]
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
            aa_on: if self.aa_on { 1.0 } else { 0.0 },
            _pad: [0.0; 2],
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
