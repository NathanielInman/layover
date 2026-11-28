//! Procedural 3D mesh data and built-in primitives for Tier M hacks (`mesh: Some(...)`).

use anyhow::{Result, bail};
use bytemuck::{Pod, Zeroable};
use std::f32::consts::TAU;

/// Interleaved vertex shared by every Tier M mesh primitive.
#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct MeshVertex {
    pub pos: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
}

impl MeshVertex {
    pub const ATTRIBS: [wgpu::VertexAttribute; 3] = wgpu::vertex_attr_array![
        0 => Float32x3,
        1 => Float32x3,
        2 => Float32x2,
    ];

    pub const LAYOUT: wgpu::VertexBufferLayout<'static> = wgpu::VertexBufferLayout {
        array_stride: size_of::<MeshVertex>() as wgpu::BufferAddress,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &Self::ATTRIBS,
    };
}

/// Indexed triangle mesh in unit object space (`TriangleList`, CCW outward).
#[derive(Clone, Debug, Default)]
pub struct MeshData {
    pub vertices: Vec<MeshVertex>,
    pub indices: Vec<u32>,
}

impl MeshData {
    /// Verify vertices and triangle indices are valid and finite before GPU upload.
    pub fn validate(&self) -> Result<()> {
        if self.vertices.is_empty() {
            bail!("mesh has no vertices");
        }
        if self.indices.is_empty() {
            bail!("mesh has no indices");
        }
        if !self.indices.len().is_multiple_of(3) {
            bail!("mesh index count {} is not a multiple of 3", self.indices.len());
        }
        for (i, v) in self.vertices.iter().enumerate() {
            if !v.pos.into_iter().chain(v.normal).chain(v.uv).all(f32::is_finite) {
                bail!("mesh vertex {i} has non-finite data");
            }
        }
        let n = self.vertices.len();
        for (i, &idx) in self.indices.iter().enumerate() {
            if idx as usize >= n {
                bail!("mesh index {idx} at {i} exceeds vertex count {n}");
            }
        }
        Ok(())
    }
}

/// Geometry source for one Tier M `MeshDraw`.
#[derive(Clone, Copy, Debug)]
pub enum MeshSource {
    Cube,
    Sphere,
    Cylinder,
    Torus,
    Cone,
    Octahedron,
    Icosahedron,
    HexPrism,
    Gear,
    Custom(fn() -> MeshData),
}

impl MeshSource {
    /// Build unit-scale triangle geometry centered at the origin.
    pub fn build(self) -> MeshData {
        match self {
            MeshSource::Cube => cube(),
            MeshSource::Sphere => sphere(24, 16),
            MeshSource::Cylinder => cylinder(24),
            MeshSource::Torus => torus(0.35, 0.15, 28, 14),
            MeshSource::Cone => cone(24),
            MeshSource::Octahedron => octahedron(),
            MeshSource::Icosahedron => icosahedron(),
            MeshSource::HexPrism => hex_prism(),
            MeshSource::Gear => gear(12),
            MeshSource::Custom(f) => f(),
        }
    }
}

fn norm3(v: [f32; 3]) -> [f32; 3] {
    let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt().max(1e-8);
    [v[0] / l, v[1] / l, v[2] / l]
}

fn sub3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

fn dot3(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn push_quad(m: &mut MeshData, a: u32, b: u32, c: u32, d: u32) {
    m.indices.extend_from_slice(&[a, b, c, a, c, d]);
}

fn push_outward_flat_tri(m: &mut MeshData, p0: [f32; 3], mut p1: [f32; 3], mut p2: [f32; 3]) {
    let mut n = cross3(sub3(p1, p0), sub3(p2, p0));
    let centroid = [p0[0] + p1[0] + p2[0], p0[1] + p1[1] + p2[1], p0[2] + p1[2] + p2[2]];
    if dot3(n, centroid) < 0.0 {
        std::mem::swap(&mut p1, &mut p2);
        n = [-n[0], -n[1], -n[2]];
    }
    let normal = norm3(n);
    let base = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: p0, normal, uv: [0.0, 0.0] });
    m.vertices.push(MeshVertex { pos: p1, normal, uv: [1.0, 0.0] });
    m.vertices.push(MeshVertex { pos: p2, normal, uv: [0.5, 1.0] });
    m.indices.extend_from_slice(&[base, base + 1, base + 2]);
}

fn cube() -> MeshData {
    let mut m = MeshData::default();
    let faces: [([f32; 3], [[f32; 3]; 4]); 6] = [
        ([0.0, 0.0, 1.0], [[-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]]),
        (
            [0.0, 0.0, -1.0],
            [[0.5, -0.5, -0.5], [-0.5, -0.5, -0.5], [-0.5, 0.5, -0.5], [0.5, 0.5, -0.5]],
        ),
        ([1.0, 0.0, 0.0], [[0.5, -0.5, 0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5]]),
        (
            [-1.0, 0.0, 0.0],
            [[-0.5, -0.5, -0.5], [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [-0.5, 0.5, -0.5]],
        ),
        ([0.0, 1.0, 0.0], [[-0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5]]),
        (
            [0.0, -1.0, 0.0],
            [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5]],
        ),
    ];
    let uvs = [[0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]];
    for (normal, pts) in faces {
        let base = m.vertices.len() as u32;
        for (pos, uv) in pts.into_iter().zip(uvs) {
            m.vertices.push(MeshVertex { pos, normal, uv });
        }
        push_quad(&mut m, base, base + 1, base + 2, base + 3);
    }
    m
}

fn sphere(segs: u32, rings: u32) -> MeshData {
    let mut m = MeshData::default();
    let r = 0.5f32;
    let north = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, r, 0.0], normal: [0.0, 1.0, 0.0], uv: [0.5, 0.0] });
    let south = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, -r, 0.0], normal: [0.0, -1.0, 0.0], uv: [0.5, 1.0] });

    let ring_count = rings.max(3);
    let inner_rings = ring_count - 1;
    let ring_base = m.vertices.len() as u32;
    for j in 1..ring_count {
        let v = j as f32 / ring_count as f32;
        let phi = v * std::f32::consts::PI;
        let (sp, cp) = (phi.sin(), phi.cos());
        for i in 0..=segs {
            let u = i as f32 / segs as f32;
            let theta = u * TAU;
            let normal = [sp * theta.cos(), cp, -sp * theta.sin()];
            m.vertices.push(MeshVertex {
                pos: [normal[0] * r, normal[1] * r, normal[2] * r],
                normal,
                uv: [u, v],
            });
        }
    }

    let stride = segs + 1;
    for i in 0..segs {
        let a = ring_base + i;
        let b = ring_base + i + 1;
        m.indices.extend_from_slice(&[north, a, b]);
    }
    for j in 0..inner_rings - 1 {
        let r0 = ring_base + j * stride;
        let r1 = r0 + stride;
        for i in 0..segs {
            push_quad(&mut m, r0 + i, r1 + i, r1 + i + 1, r0 + i + 1);
        }
    }
    let last_ring = ring_base + (inner_rings - 1) * stride;
    for i in 0..segs {
        let a = last_ring + i;
        let b = last_ring + i + 1;
        m.indices.extend_from_slice(&[a, south, b]);
    }
    m
}

fn cylinder(segs: u32) -> MeshData {
    let mut m = MeshData::default();
    let r = 0.5f32;
    let side_base = m.vertices.len() as u32;
    for i in 0..=segs {
        let u = i as f32 / segs as f32;
        let theta = u * TAU;
        let nx = theta.cos();
        let nz = -theta.sin();
        m.vertices.push(MeshVertex {
            pos: [nx * r, 0.5, nz * r],
            normal: [nx, 0.0, nz],
            uv: [u, 0.0],
        });
        m.vertices.push(MeshVertex {
            pos: [nx * r, -0.5, nz * r],
            normal: [nx, 0.0, nz],
            uv: [u, 1.0],
        });
    }
    for i in 0..segs {
        let t0 = side_base + i * 2;
        let b0 = t0 + 1;
        let t1 = t0 + 2;
        let b1 = t0 + 3;
        push_quad(&mut m, t0, b0, b1, t1);
    }

    let top_center = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, 0.5, 0.0], normal: [0.0, 1.0, 0.0], uv: [0.5, 0.5] });
    let top_rim = m.vertices.len() as u32;
    for i in 0..=segs {
        let theta = (i as f32 / segs as f32) * TAU;
        let (ct, st) = (theta.cos(), theta.sin());
        m.vertices.push(MeshVertex {
            pos: [ct * r, 0.5, -st * r],
            normal: [0.0, 1.0, 0.0],
            uv: [0.5 + 0.5 * ct, 0.5 - 0.5 * st],
        });
    }
    for i in 0..segs {
        m.indices.extend_from_slice(&[top_center, top_rim + i, top_rim + i + 1]);
    }

    let bot_center = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, -0.5, 0.0], normal: [0.0, -1.0, 0.0], uv: [0.5, 0.5] });
    let bot_rim = m.vertices.len() as u32;
    for i in 0..=segs {
        let theta = (i as f32 / segs as f32) * TAU;
        let (ct, st) = (theta.cos(), theta.sin());
        m.vertices.push(MeshVertex {
            pos: [ct * r, -0.5, -st * r],
            normal: [0.0, -1.0, 0.0],
            uv: [0.5 + 0.5 * ct, 0.5 + 0.5 * st],
        });
    }
    for i in 0..segs {
        m.indices.extend_from_slice(&[bot_center, bot_rim + i + 1, bot_rim + i]);
    }
    m
}

fn torus(major_r: f32, minor_r: f32, segs_maj: u32, segs_min: u32) -> MeshData {
    let mut m = MeshData::default();
    let stride = segs_min + 1;
    for i in 0..=segs_maj {
        let u = i as f32 / segs_maj as f32;
        let ang_u = u * TAU;
        let (cu, su) = (ang_u.cos(), ang_u.sin());
        for j in 0..=segs_min {
            let v = j as f32 / segs_min as f32;
            let ang_v = v * TAU;
            let (cv, sv) = (ang_v.cos(), ang_v.sin());
            let normal = [cv * cu, cv * su, sv];
            let pos = [(major_r + minor_r * cv) * cu, (major_r + minor_r * cv) * su, minor_r * sv];
            m.vertices.push(MeshVertex { pos, normal, uv: [u, v] });
        }
    }
    for i in 0..segs_maj {
        for j in 0..segs_min {
            let a = i * stride + j;
            let b = (i + 1) * stride + j;
            let c = (i + 1) * stride + j + 1;
            let d = i * stride + j + 1;
            push_quad(&mut m, a, b, c, d);
        }
    }
    m
}

fn cone(segs: u32) -> MeshData {
    let mut m = MeshData::default();
    let r = 0.5f32;
    for i in 0..segs {
        let u0 = i as f32 / segs as f32;
        let u1 = (i + 1) as f32 / segs as f32;
        let t0 = u0 * TAU;
        let t1 = u1 * TAU;
        let tm = 0.5 * (t0 + t1);
        let n0 = norm3([t0.cos(), 0.5, -t0.sin()]);
        let n1 = norm3([t1.cos(), 0.5, -t1.sin()]);
        let nm = norm3([tm.cos(), 0.5, -tm.sin()]);
        let base = m.vertices.len() as u32;
        m.vertices.push(MeshVertex {
            pos: [0.0, 0.5, 0.0],
            normal: nm,
            uv: [0.5 * (u0 + u1), 0.0],
        });
        m.vertices.push(MeshVertex {
            pos: [t0.cos() * r, -0.5, -t0.sin() * r],
            normal: n0,
            uv: [u0, 1.0],
        });
        m.vertices.push(MeshVertex {
            pos: [t1.cos() * r, -0.5, -t1.sin() * r],
            normal: n1,
            uv: [u1, 1.0],
        });
        m.indices.extend_from_slice(&[base, base + 1, base + 2]);
    }

    let bot_center = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, -0.5, 0.0], normal: [0.0, -1.0, 0.0], uv: [0.5, 0.5] });
    let bot_rim = m.vertices.len() as u32;
    for i in 0..=segs {
        let theta = (i as f32 / segs as f32) * TAU;
        let (ct, st) = (theta.cos(), theta.sin());
        m.vertices.push(MeshVertex {
            pos: [ct * r, -0.5, -st * r],
            normal: [0.0, -1.0, 0.0],
            uv: [0.5 + 0.5 * ct, 0.5 + 0.5 * st],
        });
    }
    for i in 0..segs {
        m.indices.extend_from_slice(&[bot_center, bot_rim + i + 1, bot_rim + i]);
    }
    m
}

fn octahedron() -> MeshData {
    let mut m = MeshData::default();
    let v = [
        [0.0, 0.5, 0.0],
        [0.0, -0.5, 0.0],
        [0.5, 0.0, 0.0],
        [-0.5, 0.0, 0.0],
        [0.0, 0.0, 0.5],
        [0.0, 0.0, -0.5],
    ];
    let tris =
        [[0, 4, 2], [0, 2, 5], [0, 5, 3], [0, 3, 4], [1, 2, 4], [1, 5, 2], [1, 3, 5], [1, 4, 3]];
    for [a, b, c] in tris {
        push_outward_flat_tri(&mut m, v[a], v[b], v[c]);
    }
    m
}

fn icosahedron() -> MeshData {
    let mut m = MeshData::default();
    let phi = 0.5 * (1.0 + 5.0f32.sqrt());
    let verts = [
        [-1.0, phi, 0.0],
        [1.0, phi, 0.0],
        [-1.0, -phi, 0.0],
        [1.0, -phi, 0.0],
        [0.0, -1.0, phi],
        [0.0, 1.0, phi],
        [0.0, -1.0, -phi],
        [0.0, 1.0, -phi],
        [phi, 0.0, -1.0],
        [phi, 0.0, 1.0],
        [-phi, 0.0, -1.0],
        [-phi, 0.0, 1.0],
    ]
    .map(|p| {
        let u = norm3(p);
        [u[0] * 0.5, u[1] * 0.5, u[2] * 0.5]
    });
    let tris = [
        [0, 11, 5],
        [0, 5, 1],
        [0, 1, 7],
        [0, 7, 10],
        [0, 10, 11],
        [1, 5, 9],
        [5, 11, 4],
        [11, 10, 2],
        [10, 7, 6],
        [7, 1, 8],
        [3, 9, 4],
        [3, 4, 2],
        [3, 2, 6],
        [3, 6, 8],
        [3, 8, 9],
        [4, 9, 5],
        [2, 4, 11],
        [6, 2, 10],
        [8, 6, 7],
        [9, 8, 1],
    ];
    for [a, b, c] in tris {
        push_outward_flat_tri(&mut m, verts[a], verts[b], verts[c]);
    }
    m
}

fn hex_prism() -> MeshData {
    let mut m = MeshData::default();
    let segs = 6u32;
    let r = 0.5f32;
    for i in 0..segs {
        let u0 = i as f32 / segs as f32;
        let u1 = (i + 1) as f32 / segs as f32;
        let t0 = u0 * TAU;
        let t1 = u1 * TAU;
        let tm = 0.5 * (t0 + t1);
        let normal = norm3([tm.cos(), 0.0, -tm.sin()]);
        let base = m.vertices.len() as u32;
        m.vertices.push(MeshVertex {
            pos: [t0.cos() * r, 0.5, -t0.sin() * r],
            normal,
            uv: [u0, 0.0],
        });
        m.vertices.push(MeshVertex {
            pos: [t0.cos() * r, -0.5, -t0.sin() * r],
            normal,
            uv: [u0, 1.0],
        });
        m.vertices.push(MeshVertex {
            pos: [t1.cos() * r, -0.5, -t1.sin() * r],
            normal,
            uv: [u1, 1.0],
        });
        m.vertices.push(MeshVertex {
            pos: [t1.cos() * r, 0.5, -t1.sin() * r],
            normal,
            uv: [u1, 0.0],
        });
        push_quad(&mut m, base, base + 1, base + 2, base + 3);
    }

    let top_center = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, 0.5, 0.0], normal: [0.0, 1.0, 0.0], uv: [0.5, 0.5] });
    let top_rim = m.vertices.len() as u32;
    for i in 0..=segs {
        let theta = (i as f32 / segs as f32) * TAU;
        let (ct, st) = (theta.cos(), theta.sin());
        m.vertices.push(MeshVertex {
            pos: [ct * r, 0.5, -st * r],
            normal: [0.0, 1.0, 0.0],
            uv: [0.5 + 0.5 * ct, 0.5 - 0.5 * st],
        });
    }
    for i in 0..segs {
        m.indices.extend_from_slice(&[top_center, top_rim + i, top_rim + i + 1]);
    }

    let bot_center = m.vertices.len() as u32;
    m.vertices.push(MeshVertex { pos: [0.0, -0.5, 0.0], normal: [0.0, -1.0, 0.0], uv: [0.5, 0.5] });
    let bot_rim = m.vertices.len() as u32;
    for i in 0..=segs {
        let theta = (i as f32 / segs as f32) * TAU;
        let (ct, st) = (theta.cos(), theta.sin());
        m.vertices.push(MeshVertex {
            pos: [ct * r, -0.5, -st * r],
            normal: [0.0, -1.0, 0.0],
            uv: [0.5 + 0.5 * ct, 0.5 + 0.5 * st],
        });
    }
    for i in 0..segs {
        m.indices.extend_from_slice(&[bot_center, bot_rim + i + 1, bot_rim + i]);
    }
    m
}

fn gear(teeth: u32) -> MeshData {
    let mut m = MeshData::default();
    let r_tip = 0.50f32;
    let r_root = 0.38f32;
    let r_bore = 0.16f32;
    let hz = 0.12f32;
    let step = TAU / teeth as f32;

    let mut outer_pts = Vec::with_capacity(teeth as usize * 4);
    let mut inner_pts = Vec::with_capacity(teeth as usize * 4);
    for i in 0..teeth {
        let a0 = i as f32 * step;
        let pattern = [
            (a0, r_root),
            (a0 + step * 0.18, r_tip),
            (a0 + step * 0.42, r_tip),
            (a0 + step * 0.60, r_root),
        ];
        for (ang, rad) in pattern {
            let (ca, sa) = (ang.cos(), ang.sin());
            outer_pts.push([rad * ca, rad * sa]);
            inner_pts.push([r_bore * ca, r_bore * sa]);
        }
    }

    let n = outer_pts.len();
    for k in 0..n {
        let k1 = (k + 1) % n;
        let (o0, o1) = (outer_pts[k], outer_pts[k1]);
        let (i0, i1) = (inner_pts[k], inner_pts[k1]);

        let bf = m.vertices.len() as u32;
        for (pos, uv) in [
            ([i0[0], i0[1], hz], [0.5 + i0[0], 0.5 + i0[1]]),
            ([o0[0], o0[1], hz], [0.5 + o0[0], 0.5 + o0[1]]),
            ([o1[0], o1[1], hz], [0.5 + o1[0], 0.5 + o1[1]]),
            ([i1[0], i1[1], hz], [0.5 + i1[0], 0.5 + i1[1]]),
        ] {
            m.vertices.push(MeshVertex { pos, normal: [0.0, 0.0, 1.0], uv });
        }
        push_quad(&mut m, bf, bf + 1, bf + 2, bf + 3);

        let bb = m.vertices.len() as u32;
        for (pos, uv) in [
            ([i0[0], i0[1], -hz], [0.5 + i0[0], 0.5 + i0[1]]),
            ([i1[0], i1[1], -hz], [0.5 + i1[0], 0.5 + i1[1]]),
            ([o1[0], o1[1], -hz], [0.5 + o1[0], 0.5 + o1[1]]),
            ([o0[0], o0[1], -hz], [0.5 + o0[0], 0.5 + o0[1]]),
        ] {
            m.vertices.push(MeshVertex { pos, normal: [0.0, 0.0, -1.0], uv });
        }
        push_quad(&mut m, bb, bb + 1, bb + 2, bb + 3);

        let edge = [o1[0] - o0[0], o1[1] - o0[1]];
        let wall_n = norm3([edge[1], -edge[0], 0.0]);
        let u0 = k as f32 / n as f32;
        let u1 = (k + 1) as f32 / n as f32;
        let bw = m.vertices.len() as u32;
        m.vertices.push(MeshVertex { pos: [o0[0], o0[1], hz], normal: wall_n, uv: [u0, 0.0] });
        m.vertices.push(MeshVertex { pos: [o0[0], o0[1], -hz], normal: wall_n, uv: [u0, 1.0] });
        m.vertices.push(MeshVertex { pos: [o1[0], o1[1], -hz], normal: wall_n, uv: [u1, 1.0] });
        m.vertices.push(MeshVertex { pos: [o1[0], o1[1], hz], normal: wall_n, uv: [u1, 0.0] });
        push_quad(&mut m, bw, bw + 1, bw + 2, bw + 3);

        let ni0 = norm3([-i0[0], -i0[1], 0.0]);
        let ni1 = norm3([-i1[0], -i1[1], 0.0]);
        let bi = m.vertices.len() as u32;
        m.vertices.push(MeshVertex { pos: [i0[0], i0[1], hz], normal: ni0, uv: [u0, 0.0] });
        m.vertices.push(MeshVertex { pos: [i1[0], i1[1], hz], normal: ni1, uv: [u1, 0.0] });
        m.vertices.push(MeshVertex { pos: [i1[0], i1[1], -hz], normal: ni1, uv: [u1, 1.0] });
        m.vertices.push(MeshVertex { pos: [i0[0], i0[1], -hz], normal: ni0, uv: [u0, 1.0] });
        push_quad(&mut m, bi, bi + 1, bi + 2, bi + 3);
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vertex_layout_matches_struct_size() {
        assert_eq!(size_of::<MeshVertex>(), 32);
        assert_eq!(MeshVertex::LAYOUT.array_stride, 32);
    }

    #[test]
    fn all_builtin_primitives_are_valid_outward_ccw_manifolds() {
        let builtins = [
            MeshSource::Cube,
            MeshSource::Sphere,
            MeshSource::Cylinder,
            MeshSource::Torus,
            MeshSource::Cone,
            MeshSource::Octahedron,
            MeshSource::Icosahedron,
            MeshSource::HexPrism,
            MeshSource::Gear,
        ];
        for src in builtins {
            let m = src.build();
            m.validate().unwrap_or_else(|e| panic!("{src:?} invalid: {e}"));

            let mut max_r = 0.0f32;
            for (i, v) in m.vertices.iter().enumerate() {
                let n_len = (v.normal[0] * v.normal[0]
                    + v.normal[1] * v.normal[1]
                    + v.normal[2] * v.normal[2])
                    .sqrt();
                assert!((n_len - 1.0).abs() < 1e-3, "{src:?} vertex {i} non-unit normal {n_len}");
                let r = (v.pos[0] * v.pos[0] + v.pos[1] * v.pos[1] + v.pos[2] * v.pos[2]).sqrt();
                max_r = max_r.max(r);
            }
            assert!((0.45..=0.90).contains(&max_r), "{src:?} unexpected bounding radius {max_r}");

            let mut signed_vol = 0.0f32;
            for &[i0, i1, i2] in m.indices.as_chunks::<3>().0 {
                let va = m.vertices[i0 as usize];
                let vb = m.vertices[i1 as usize];
                let vc = m.vertices[i2 as usize];
                let fn_raw = cross3(sub3(vb.pos, va.pos), sub3(vc.pos, va.pos));
                let n_avg = [
                    va.normal[0] + vb.normal[0] + vc.normal[0],
                    va.normal[1] + vb.normal[1] + vc.normal[1],
                    va.normal[2] + vb.normal[2] + vc.normal[2],
                ];
                let area = dot3(fn_raw, fn_raw).sqrt();
                assert!(area > 1e-8, "{src:?} degenerate triangle with area {area}");
                assert!(
                    dot3(fn_raw, n_avg) > 0.0,
                    "{src:?} triangle has inward winding: fn={fn_raw:?}, n_avg={n_avg:?}"
                );
                signed_vol += dot3(va.pos, cross3(vb.pos, vc.pos)) / 6.0;
            }
            assert!(signed_vol > 0.0, "{src:?} non-positive signed enclosed volume {signed_vol}");
        }
    }
}
