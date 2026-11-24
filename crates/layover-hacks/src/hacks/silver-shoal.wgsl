// Silver Shoal: bioluminescent boid schools and darting swarms weaving, banking
// and scattering across the dark on Tier P compute particles and advected
// Tier S feedback textures.
// After xscreensaver's GLSchool (David C. Lambert) and Swarm (Jeff Butterworth).
//
// Race-free Jacobi ping-pong particle buffer (`Particles { count: 640 }`):
//   Half 0 (`0..319`) and Half 1 (`320..639`) alternate as read/write halves
//   according to `u32(round(max(g.frame, 0.0))) & 1u`.
//
// Particle layout (`particles[idx]`):
//   p.xyz = 3D position relative to school center (canvas heights)
//   p.w   = banking / predator-evasion iridescence flash energy (0..1)
//   v.xyz = 3D velocity relative to school center (canvas heights/sec)
//   v.w   = swim undulation phase (radians, wrapped modulo TAU)
//   c.rgb = base iridescent RGB color
//   c.w   = packed epoch `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninitialized)

const MAX_AGENTS: u32 = 320u;
const DRIFT_VX: f32 = 0.145;
const EPOCH_SECS: f32 = 34.0;

struct RegimeSpec {
    sep_r: f32,
    align_r: f32,
    cohes_r: f32,
    w_sep: f32,
    w_align: f32,
    w_cohes: f32,
    w_goal: f32,
    turn_rate: f32,
    v_min: f32,
    v_max: f32,
    bound_xy: f32,
    bound_z: f32,
};

fn rotate_3d(v: vec3<f32>, yaw: f32, pitch: f32, roll: f32) -> vec3<f32> {
    let xz = rot2(yaw) * v.xz;
    let v1 = vec3<f32>(xz.x, v.y, xz.y);
    let yz = rot2(pitch) * v1.yz;
    let v2 = vec3<f32>(v1.x, yz.x, yz.y);
    let xy = rot2(roll) * v2.xy;
    return vec3<f32>(xy.x, xy.y, v2.z);
}

fn safe_norm3(v: vec3<f32>, fallback: vec3<f32>) -> vec3<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn safe_norm2(v: vec2<f32>, fallback: vec2<f32>) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn clamp_len3(v: vec3<f32>, max_l: f32) -> vec3<f32> {
    let l2 = dot(v, v);
    if (l2 > max_l * max_l && l2 > 1e-12) {
        return v * (max_l * inverseSqrt(l2));
    }
    return v;
}

fn regime_spec(arch: u32, is_narrow: bool) -> RegimeSpec {
    let sx = select(1.0, 0.88, is_narrow);
    if (arch == 0u) {
        // Pelagic Baitball (GLSchool + Predator): airy 3D swirl with sharp predator burst scatter.
        return RegimeSpec(
            0.105, 0.190, 0.300,
            2.35, 1.05, 0.55, 0.72,
            4.8, 0.40, 0.94, 0.40 * sx, 0.25,
        );
    }
    if (arch == 1u) {
        // Reef Ribbon Current (GLSchool Stream): sinuous staggered ribbons along 3D Lissajous streams.
        return RegimeSpec(
            0.095, 0.175, 0.210,
            2.10, 1.15, 0.28, 1.55,
            4.6, 0.46, 0.90, 0.42 * sx, 0.24,
        );
    }
    if (arch == 2u) {
        // Wasp & Firefly Swarm (XSwarm): expansive agile bees whipping around twin asynchronous queens.
        return RegimeSpec(
            0.072, 0.120, 0.140,
            1.65, 0.22, 0.12, 2.40,
            5.8, 0.52, 1.32, 0.44 * sx, 0.25,
        );
    }
    // Abyssal Torus Vortex (GLSchool Mill): evenly spaced 3D vortex ring parted periodically by a hunter.
    return RegimeSpec(
        0.098, 0.145, 0.180,
        2.25, 0.95, 0.22, 1.55,
        4.6, 0.44, 0.92, 0.38 * sx, 0.23,
    );
}

// Four R/G/B-balanced bioluminescent palettes across body roles and leaders.
fn school_palette(pal: u32, role: u32, is_leader: bool) -> vec3<f32> {
    let p = pal % 4u;
    let r = role % 4u;

    if (p == 0u) {
        // Pelagic Silver & Coral
        if (is_leader) {
            return vec3<f32>(1.00, 0.76, 0.22);
        }
        if (r == 0u) {
            return vec3<f32>(0.22, 0.90, 1.00);
        }
        if (r == 1u) {
            return vec3<f32>(0.14, 0.98, 0.68);
        }
        if (r == 2u) {
            return vec3<f32>(1.00, 0.42, 0.26);
        }
        return vec3<f32>(0.42, 0.66, 1.00);
    }
    if (p == 1u) {
        // Abyssal Biolume
        if (is_leader) {
            return vec3<f32>(1.00, 0.26, 0.44);
        }
        if (r == 0u) {
            return vec3<f32>(0.18, 0.64, 1.00);
        }
        if (r == 1u) {
            return vec3<f32>(0.12, 0.98, 0.84);
        }
        if (r == 2u) {
            return vec3<f32>(0.74, 0.34, 1.00);
        }
        return vec3<f32>(0.34, 0.94, 0.46);
    }
    if (p == 2u) {
        // Koi & Jade Lantern
        if (is_leader) {
            return vec3<f32>(0.20, 0.84, 1.00);
        }
        if (r == 0u) {
            return vec3<f32>(1.00, 0.38, 0.16);
        }
        if (r == 1u) {
            return vec3<f32>(0.14, 0.96, 0.56);
        }
        if (r == 2u) {
            return vec3<f32>(1.00, 0.76, 0.22);
        }
        return vec3<f32>(0.98, 0.28, 0.64);
    }
    // Firefly Dusk
    if (is_leader) {
        return vec3<f32>(1.00, 0.28, 0.74);
    }
    if (r == 0u) {
        return vec3<f32>(1.00, 0.76, 0.18);
    }
    if (r == 1u) {
        return vec3<f32>(0.52, 0.98, 0.24);
    }
    if (r == 2u) {
        return vec3<f32>(0.20, 0.86, 1.00);
    }
    return vec3<f32>(0.70, 0.38, 1.00);
}

fn school_center(school_id: u32, n_schools: u32, gen: u32, t: f32) -> vec2<f32> {
    let a = aspect();
    let fs = f32(school_id);
    let fg = f32(gen);
    let jx = (hash11(fs * 19.7 + fg * 31.3 + g.seed * 59.0) - 0.5) * 0.22;
    let x0 = fract((fs + 0.5 + jx) / f32(n_schools) + g.seed * 0.41) * a;
    let y_base = 0.38 + 0.24 * fract(0.21 + fs * 0.47 + fg * 0.618034 + g.seed * 0.53);
    let y_sway = 0.055 * sin(t * 0.27 + fs * 2.1 + fg * 1.3);
    return vec2<f32>(
        fract((x0 + DRIFT_VX * t) / a) * a,
        clamp(y_base + y_sway, 0.32, 0.68),
    );
}

fn school_camera_angles(school_id: u32, gen: u32, phase: f32) -> vec3<f32> {
    let fs = f32(school_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fs * 17.3 + fg * 37.9, g.seed * 61.0 + 4.3));
    let yaw = 0.32 * sin(phase * 0.09 + h.x * TAU) + (h.y - 0.5) * 0.42;
    let pitch = 0.28 * cos(phase * 0.07 + h.y * TAU) + (h.x - 0.5) * 0.34;
    let roll = 0.14 * sin(phase * 0.05 + h.x * 4.1);
    return vec3<f32>(yaw, pitch, roll);
}

fn project_local(p3: vec3<f32>, school_id: u32, gen: u32, phase: f32) -> vec3<f32> {
    let ang = school_camera_angles(school_id, gen, phase);
    let r = rotate_3d(p3, ang.x, ang.y, ang.z);
    let persp = 1.0 / (1.0 + clamp(r.z, -0.55, 1.25) * 0.42);
    return vec3<f32>(r.xy * persp, r.z);
}

// Smooth 3D Lissajous figure-8 stream for Reef Ribbon Current (arch == 1u).
fn ribbon_target(s_phase: f32, school_id: u32, gen: u32, is_narrow: bool, branch: u32) -> vec3<f32> {
    let sx = select(1.0, 0.86, is_narrow);
    let ph = hash11(f32(school_id) * 13.7 + f32(gen) * 29.1 + g.seed * 43.0) * TAU;
    let w = s_phase * 0.78 + ph + f32(branch) * PI;
    return vec3<f32>(
        0.37 * sx * sin(w * 1.00),
        0.22 * sin(w * 2.00 + 0.4),
        0.16 * cos(w * 1.50 - 0.3),
    );
}

// Agile 3D Queen / Wasp path for XSwarm (arch == 2u).
fn wasp_target(phase: f32, wasp_id: u32, school_id: u32, gen: u32, is_narrow: bool) -> vec3<f32> {
    let sx = select(1.0, 0.86, is_narrow);
    let fw = f32(wasp_id);
    let ph = hash11(f32(school_id) * 23.1 + f32(gen) * 19.7 + fw * 7.3 + g.seed * 53.0) * TAU;
    let dir = select(-1.0, 1.0, wasp_id == 0u);
    let w = phase * (1.22 + 0.21 * fw) * dir + ph;
    return vec3<f32>(
        0.38 * sx * (0.68 * cos(w) + 0.32 * sin(w * 2.15 + 0.9)),
        0.26 * (0.66 * sin(w * 1.45 + 0.5) + 0.34 * cos(w * 2.75)),
        0.18 * sin(w * 1.85 - 0.6),
    );
}

// Predator stalking / lunging loop for Baitball (arch == 0u) and Mill surge (arch == 3u).
fn predator_target(arch: u32, phase: f32, school_id: u32, gen: u32, is_narrow: bool) -> vec3<f32> {
    let sx = select(1.0, 0.86, is_narrow);
    let ph = hash11(f32(school_id) * 31.1 + f32(gen) * 17.9 + g.seed * 71.0) * TAU;
    let cycle = fract((phase + ph) / 7.2);
    // Periodic dive through the heart of the school, then wide circling stalk.
    let lunge = exp(-pow((cycle - 0.5) * 6.5, 2.0));
    let w = phase * 0.72 + ph;
    let r = mix(0.35, 0.04, lunge);
    let z_amp = select(0.15, 0.16, arch == 3u);
    return vec3<f32>(
        r * sx * cos(w),
        r * 0.74 * sin(w * 1.3 + 0.6),
        z_amp * sin(w * 1.9 - 0.4),
    );
}

fn spawn_agent(
    arch: u32,
    pal_id: u32,
    spec: RegimeSpec,
    school_id: u32,
    local_id: u32,
    agents_per: u32,
    gen: u32,
    is_narrow: bool,
) -> Particle {
    let fl = f32(local_id);
    let fs = f32(school_id);
    let fg = f32(gen);
    let h0 = hash22(vec2<f32>(fl * 1.93 + fs * 17.3, fg * 31.7 + g.seed * 67.0));
    let h1 = hash22(vec2<f32>(fl * 3.11 + fg * 23.9, fs * 41.7 + g.seed * 53.0));

    let is_pred = (arch == 0u || arch == 3u) && local_id == 0u;
    let is_wasp = (arch == 2u) && (local_id < 2u);
    let is_leader = is_pred || is_wasp;

    var pos = vec3<f32>(0.0);
    var vel = vec3<f32>(0.0);
    let u = (fl + 0.5) / max(f32(agents_per), 1.0);
    let ang = fl * 2.3999632 + h0.x * 0.6 + fs * 1.9;

    if (is_pred) {
        pos = predator_target(arch, 0.0, school_id, gen, is_narrow);
        vel = safe_norm3(predator_target(arch, 0.05, school_id, gen, is_narrow) - pos, vec3<f32>(1.0, 0.0, 0.0)) * 0.70;
    } else if (is_wasp) {
        pos = wasp_target(0.0, local_id, school_id, gen, is_narrow);
        vel = safe_norm3(wasp_target(0.05, local_id, school_id, gen, is_narrow) - pos, vec3<f32>(0.0, 1.0, 0.0)) * 1.05;
    } else if (arch == 3u) {
        // Torus mill evenly spaced around the 3D ring.
        let ring_a = u * TAU + fs * 0.7;
        let ring_r = 0.21 + 0.055 * (h0.x - 0.5);
        pos = vec3<f32>(
            ring_r * cos(ring_a),
            ring_r * sin(ring_a) * 0.85,
            0.055 * (h0.y - 0.5),
        );
        vel = normalize(vec3<f32>(-sin(ring_a), cos(ring_a), 0.12 * (h1.x - 0.5))) * 0.64;
    } else if (arch == 1u) {
        // Staggered along twin sinuous 3D ribbon curves across the whole cycle.
        let branch = local_id % 2u;
        let stream_t = (1.0 - u) * 7.6;
        let p_a = ribbon_target(stream_t, school_id, gen, is_narrow, branch);
        let p_b = ribbon_target(stream_t + 0.12, school_id, gen, is_narrow, branch);
        let lat_off = vec3<f32>(h0.x - 0.5, h0.y - 0.5, h1.x - 0.5) * 0.11;
        pos = p_a + lat_off;
        vel = safe_norm3(p_b - p_a, vec3<f32>(1.0, 0.0, 0.0)) * 0.64;
    } else if (arch == 2u) {
        // Expansive cloud around the twin wasp trajectories.
        let wid = local_id % 2u;
        let center_w = wasp_target(0.0, wid, school_id, gen, is_narrow);
        let rr = 0.08 + pow(u, 0.6) * 0.24;
        let phi = acos(clamp(1.0 - 2.0 * h0.y, -0.98, 0.98));
        pos = center_w * 0.55 + vec3<f32>(
            rr * sin(phi) * cos(ang),
            rr * sin(phi) * sin(ang) * 0.80,
            rr * cos(phi) * 0.65,
        );
        vel = safe_norm3(vec3<f32>(-sin(ang), cos(ang), h1.x - 0.5), vec3<f32>(1.0, 0.0, 0.0)) * 0.82;
    } else {
        // Spherical Fibonacci / golden-spiral school cloud with airy spacing.
        let rr = 0.06 + pow(u, 0.45) * 0.29;
        let phi = acos(clamp(1.0 - 2.0 * h0.y, -0.98, 0.98));
        pos = vec3<f32>(
            rr * sin(phi) * cos(ang),
            rr * sin(phi) * sin(ang) * 0.80,
            rr * cos(phi) * 0.65,
        );
        let tang = safe_norm3(vec3<f32>(-pos.y, pos.x, 0.22 * (h1.x - 0.5)), vec3<f32>(1.0, 0.0, 0.0));
        vel = tang * mix(spec.v_min, spec.v_max * 0.78, h1.y);
    }

    let role = local_id % 4u;
    let col = school_palette(pal_id, role, is_leader);
    let swim_phase = fract(h0.x + h1.y) * TAU;
    let packed_gen = f32((gen % 16777215u) + 1u);

    var out: Particle;
    out.p = vec4<f32>(pos, select(0.15, 0.42, is_leader));
    out.v = vec4<f32>(vel, swim_phase);
    out.c = vec4<f32>(col, packed_gen);
    return out;
}

// Rasterize an undulating 3D fish silhouette into `splat_buf` with energy-conserving AA.
fn splat_fish(
    school_cm: vec2<f32>,
    p_cur3: vec3<f32>,
    p_prev3: vec3<f32>,
    v3: vec3<f32>,
    col: vec3<f32>,
    swim_phase: f32,
    flash: f32,
    is_pred: bool,
    school_id: u32,
    gen: u32,
    phase: f32,
    env: f32,
    wrap_a: f32,
) {
    if (env <= 0.003) {
        return;
    }
    let proj_c = project_local(p_cur3, school_id, gen, phase);
    let world_c = school_cm + proj_c.xy;
    let y_clip = smoothstep(0.04, 0.09, world_c.y) * (1.0 - smoothstep(0.91, 0.96, world_c.y));
    let alpha_env = env * y_clip;
    if (alpha_env <= 0.003) {
        return;
    }

    let proj_tip = project_local(p_cur3 + safe_norm3(v3, vec3<f32>(1.0, 0.0, 0.0)) * 0.04, school_id, gen, phase);
    let d_proj = proj_tip.xy - proj_c.xy;
    let fwd = safe_norm2(d_proj, vec2<f32>(1.0, 0.0));
    let right = vec2<f32>(-fwd.y, fwd.x);
    let persp = 1.0 / (1.0 + clamp(proj_c.z, -0.55, 1.25) * 0.42);
    let fshort = clamp(length(d_proj) / (0.04 * persp), 0.42, 1.0);

    // Sleek fusiform dimensions in canvas heights.
    let base_len = select(0.062, 0.096, is_pred) * persp * mix(0.56, 1.0, fshort);
    let base_hw = select(0.0108, 0.0168, is_pred) * persp;
    let w_d = clamp(1.14 - proj_c.z * 0.46, 0.48, 1.32);

    let dims = splat_dims();
    let h = f32(dims.y);
    let len_px = base_len * h;
    let hw_px = base_hw * h;
    let hw_eff = max(hw_px, 0.65);
    let energy = clamp(hw_px / hw_eff, 0.30, 1.0);

    // Slipstream wake bridge across rapid motion steps.
    let proj_p = project_local(p_prev3, school_id, gen, phase);
    let world_p = school_cm + proj_p.xy;
    let step_d = length(world_c - world_p);
    if (step_d > base_len * 0.45 && step_d < 0.28) {
        let wake_col = col * (0.24 * w_d * alpha_env);
        splat_segment(
            vec2<f32>(fract(world_p.x / wrap_a) * wrap_a, world_p.y),
            vec2<f32>(fract(world_c.x / wrap_a) * wrap_a, world_c.y),
            wake_col,
            0.14 * w_d * alpha_env,
            true,
        );
    }

    let center_uv = state_uv(vec2<f32>(fract(world_c.x / wrap_a) * wrap_a, world_c.y));
    let center_px = center_uv * vec2<f32>(dims) - 0.5;
    let max_rad = select(24, 32, is_pred);
    let rad_x = clamp(i32(ceil(abs(fwd.x) * len_px * 0.62 + abs(right.x) * hw_eff * 2.2 + 1.5)), 1, max_rad);
    let rad_y = clamp(i32(ceil(abs(fwd.y) * len_px * 0.62 + abs(right.y) * hw_eff * 2.2 + 1.5)), 1, max_rad);
    let base = vec2<i32>(round(center_px));

    let inv_len = 1.0 / max(len_px, 1.0);
    let tail_amp = select(0.26, 0.22, is_pred) * len_px * 0.26;
    let irid_col = mix(col, vec3<f32>(0.94, 0.99, 1.0), 0.62);

    for (var dy = -rad_y; dy <= rad_y; dy = dy + 1) {
        let cy = base.y + dy;
        if (cy < 0 || cy >= dims.y) {
            continue;
        }
        let rel_y = center_px.y - f32(cy);
        for (var dx = -rad_x; dx <= rad_x; dx = dx + 1) {
            let cx = base.x + dx;
            let rel = vec2<f32>(f32(cx) - center_px.x, rel_y);

            // Project pixel into fish body coordinates: u along spine (+0.45 nose to -0.55 tail), v lateral.
            let u = dot(rel, fwd) * inv_len;
            if (u < -0.62 || u > 0.52) {
                continue;
            }
            let s = clamp(0.45 - u, 0.0, 1.0);
            let sway = sin(swim_phase - s * 4.5) * (tail_amp * s * s);
            let v_px = dot(rel, right) - sway;

            // Fusiform silhouette width profile + flared forked caudal fin at s > 0.74.
            var w_prof = 0.0;
            var is_fin = false;
            if (s < 0.74) {
                // Smooth teardrop body: fuller near shoulder (s ~ 0.22), tapering to narrow peduncle.
                let k_nose = smoothstep(0.0, 0.22, s);
                let k_tail = pow(clamp(1.0 - max(s - 0.20, 0.0) / 0.58, 0.0, 1.0), 0.76);
                w_prof = hw_eff * (0.16 + 0.90 * k_nose * k_tail);
                // Swept pectoral fins on the predator near s = 0.28.
                if (is_pred && s > 0.22 && s < 0.44) {
                    let fin_u = (s - 0.22) / 0.22;
                    w_prof = max(w_prof, hw_eff * (0.85 + 1.05 * sin(fin_u * PI) * fin_u));
                }
            } else {
                // Forked caudal tail fin flaring toward s = 1.0, crisply notched along the centerline.
                let tf = (s - 0.74) / 0.26;
                let outer = hw_eff * mix(0.24, 1.05, tf);
                let notch = hw_eff * max(tf - 0.22, 0.0) * 0.64;
                if (abs(v_px) < notch) {
                    continue;
                }
                w_prof = outer;
                is_fin = true;
            }

            let d_edge = abs(v_px) - w_prof;
            if (d_edge > 0.90) {
                continue;
            }
            let cov = (1.0 - smoothstep(-0.60, 0.60, d_edge)) * energy * alpha_env;
            if (cov <= 0.002) {
                continue;
            }

            let lat_n = clamp(abs(v_px) / max(w_prof, 0.5), 0.0, 1.0);
            let nz = sqrt(max(1.0 - lat_n * lat_n, 0.0));
            let fres = pow(1.0 - nz, 1.85);
            let lateral_line = exp(-lat_n * lat_n * 7.5) * (1.0 - smoothstep(0.62, 0.92, s));
            let fin_tint = select(1.0, 0.74, is_fin);

            var shaded = col * (0.36 + 0.48 * nz + 0.74 * fres) * fin_tint
                + irid_col * ((0.24 + 0.66 * flash) * lateral_line + 0.34 * fres);
            // Bright luminous eye / head glint near the nose.
            let nose_glow = exp(-pow((s - 0.13) * 9.5, 2.0)) * nz;
            shaded = shaded + mix(col, vec3<f32>(1.0, 0.98, 0.92), 0.68) * (nose_glow * (0.44 + 0.34 * flash));
            shaded = clamp(shaded, vec3<f32>(0.0), vec3<f32>(1.50));

            let wx = ((cx % dims.x) + dims.x) % dims.x;
            let w_splat = cov * w_d;
            splat_pixel(vec2<i32>(wx, cy), vec4<f32>(shaded * w_splat, w_splat));
        }
    }
}

// Rasterize a sleek darting wasp/firefly streak into `splat_buf` for XSwarm (arch == 2u).
fn splat_swarm(
    school_cm: vec2<f32>,
    p_cur3: vec3<f32>,
    p_prev3: vec3<f32>,
    v3: vec3<f32>,
    col: vec3<f32>,
    flash: f32,
    is_wasp: bool,
    school_id: u32,
    gen: u32,
    phase: f32,
    env: f32,
    wrap_a: f32,
) {
    if (env <= 0.003) {
        return;
    }
    let proj_c = project_local(p_cur3, school_id, gen, phase);
    let world_c = school_cm + proj_c.xy;
    let y_clip = smoothstep(0.04, 0.09, world_c.y) * (1.0 - smoothstep(0.91, 0.96, world_c.y));
    let alpha_env = env * y_clip;
    if (alpha_env <= 0.003) {
        return;
    }

    let spd = length(v3);
    let v_dir = safe_norm3(v3, vec3<f32>(1.0, 0.0, 0.0));
    let proj_tail = project_local(p_cur3 - v_dir * clamp(spd * 0.075, 0.032, 0.105), school_id, gen, phase);
    let world_tail = school_cm + proj_tail.xy;
    let w_d = clamp(1.18 - proj_c.z * 0.42, 0.52, 1.38);

    let head_w = vec2<f32>(fract(world_c.x / wrap_a) * wrap_a, world_c.y);
    let tail_w = vec2<f32>(fract(world_tail.x / wrap_a) * wrap_a, world_tail.y);
    let dims = splat_dims();
    let h = f32(dims.y);

    if (is_wasp) {
        // Vivid luminous wasp head + glowing corona + brisk tapered ribbon wake.
        let wasp_col = mix(col, vec3<f32>(1.0, 0.97, 0.92), 0.50);
        let rad = 0.0108;
        let area_scale = max(rad * h, 0.85);
        let e = area_scale * area_scale * 0.52 * w_d * alpha_env;
        splat_disc(head_w, rad, wasp_col * e, e * 1.65, true);
        splat_segment(tail_w, head_w, col * (0.95 * w_d * alpha_env), 0.32 * w_d * alpha_env, true);
    } else {
        // Crisp firefly / bee darting streak with bright glowing pinhead core.
        let head_col = mix(col, vec3<f32>(1.0, 0.98, 0.92), 0.36 + 0.36 * flash);
        let rad = 0.0056;
        let area_scale = max(rad * h, 0.72);
        let e = area_scale * area_scale * 0.40 * w_d * alpha_env;
        splat_disc(head_w, rad, head_col * e, e * 1.65, true);

        let proj_p = project_local(p_prev3, school_id, gen, phase);
        let world_p = school_cm + proj_p.xy;
        let seg_start = select(
            tail_w,
            vec2<f32>(fract(world_p.x / wrap_a) * wrap_a, world_p.y),
            length(world_c - world_p) > length(world_c - world_tail) && length(world_c - world_p) < 0.28,
        );
        splat_segment(seg_start, head_w, col * (0.88 * w_d * alpha_env), 0.26 * w_d * alpha_env, true);
    }
}

fn step_particle(idx: u32, t: f32) {
    let frame_u = u32(round(max(g.frame, 0.0)));
    let write_half = frame_u & 1u;
    let read_half = 1u - write_half;
    let read_base = read_half * MAX_AGENTS;
    let write_base = write_half * MAX_AGENTS;

    if (idx < write_base || idx >= write_base + MAX_AGENTS) {
        return;
    }

    let agent_id = idx - write_base;
    let a = aspect();
    let is_narrow = a < 2.4;
    let n_schools = select(3u, 2u, is_narrow);
    let agents_per = select(104u, 96u, is_narrow);
    if (agent_id >= n_schools * agents_per) {
        return;
    }

    let school_id = agent_id / agents_per;
    let local_id = agent_id % agents_per;
    let fs = f32(school_id);
    let school_off = (fs / f32(n_schools) + 0.13 * hash11(fs * 19.3 + g.seed * 41.0)) * EPOCH_SECS;

    let cycle_t = t + school_off;
    let gen = u32(max(floor(cycle_t / EPOCH_SECS), 0.0));
    let phase = cycle_t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.07, u_epoch) * (1.0 - smoothstep(0.92, 1.0, u_epoch));

    let arch = (gen + school_id + u32(g.seed * 13.0)) % 4u;
    let pal_id = (gen * 3u + school_id * 2u + u32(g.seed * 17.0)) % 4u;
    let spec = regime_spec(arch, is_narrow);
    let school_cm = school_center(school_id, n_schools, gen, t + g.dt);

    let st = particles[read_base + agent_id];
    let packed_now = f32((gen % 16777215u) + 1u);
    let uninit = g.frame < 0.5
        || st.c.w <= 0.5
        || abs(st.c.w - packed_now) > 0.5
        || !all(st.p.xyz == st.p.xyz)
        || !all(st.v.xyz == st.v.xyz);

    if (uninit) {
        let sp = spawn_agent(arch, pal_id, spec, school_id, local_id, agents_per, gen, is_narrow);
        particles[write_base + agent_id] = sp;
        let is_pred = (arch == 0u || arch == 3u) && local_id == 0u;
        let is_wasp = (arch == 2u) && (local_id < 2u);
        if (arch == 2u) {
            splat_swarm(school_cm, sp.p.xyz, sp.p.xyz, sp.v.xyz, sp.c.rgb, sp.p.w, is_wasp, school_id, gen, phase, env, a);
        } else {
            splat_fish(school_cm, sp.p.xyz, sp.p.xyz, sp.v.xyz, sp.c.rgb, sp.v.w, sp.p.w, is_pred, school_id, gen, phase, env, a);
        }
        return;
    }

    let dt = clamp(g.dt, 1e-4, 0.14);
    let pos = st.p.xyz;
    let vel = st.v.xyz;
    var flash = st.p.w * exp(-dt * 3.2);
    var swim_phase = st.v.w;
    let col = st.c.rgb;

    let is_pred = (arch == 0u || arch == 3u) && local_id == 0u;
    let is_wasp = (arch == 2u) && (local_id < 2u);
    let school_base = read_base + school_id * agents_per;

    var v_new = vel;
    var p_new = pos;
    var turn_rate = spec.turn_rate;
    var speed_min = spec.v_min;
    var speed_max = spec.v_max;

    if (is_pred) {
        let goal = predator_target(arch, phase + 0.18, school_id, gen, is_narrow);
        let desired = safe_norm3(goal - pos, safe_norm3(vel, vec3<f32>(1.0, 0.0, 0.0))) * 0.74;
        let k_blend = 1.0 - exp(-5.2 * dt);
        v_new = mix(vel, desired, k_blend);
        speed_min = 0.45;
        speed_max = 0.88;
        flash = max(flash, 0.25);
    } else if (is_wasp) {
        let goal = wasp_target(phase + 0.12, local_id, school_id, gen, is_narrow);
        let desired = safe_norm3(goal - pos, safe_norm3(vel, vec3<f32>(0.0, 1.0, 0.0))) * 1.15;
        let k_blend = 1.0 - exp(-8.5 * dt);
        v_new = mix(vel, desired, k_blend);
        speed_min = 0.70;
        speed_max = 1.32;
        flash = max(flash, 0.45);
    } else {
        // Reynolds 3D boids neighbor scan + predator scatter / wasp chase.
        var sep = vec3<f32>(0.0);
        var align = vec3<f32>(0.0);
        var cohes = vec3<f32>(0.0);
        var n_align = 0.0;
        var n_cohes = 0.0;
        var flee_vec = vec3<f32>(0.0);
        var flee_strength = 0.0;
        var wasp_chase = vec3<f32>(0.0);
        var best_wasp_d2 = 1e6;

        let sep_r2 = spec.sep_r * spec.sep_r;
        let align_r2 = spec.align_r * spec.align_r;
        let cohes_r2 = spec.cohes_r * spec.cohes_r;

        let pref_wasp = (local_id + u32(floor(phase * 0.16))) % 2u;

        for (var j_local = 0u; j_local < agents_per; j_local = j_local + 1u) {
            if (j_local == local_id) {
                continue;
            }
            let nb = particles[school_base + j_local];
            if (nb.c.w <= 0.5 || abs(nb.c.w - packed_now) > 0.5 || !all(nb.p.xyz == nb.p.xyz)) {
                continue;
            }
            let d = pos - nb.p.xyz;
            let dist2 = dot(d, d);
            let nb_is_pred = (arch == 0u || arch == 3u) && j_local == 0u;
            let nb_is_wasp = (arch == 2u) && (j_local < 2u);

            if (nb_is_pred) {
                if (dist2 < 0.25 * 0.25 && dist2 > 1e-6) {
                    let dist = sqrt(dist2);
                    let w_flee = smoothstep(0.25, 0.03, dist);
                    flee_vec = flee_vec + (d / dist) * (w_flee * 4.2);
                    flee_strength = max(flee_strength, w_flee);
                }
                continue;
            }

            if (nb_is_wasp) {
                // Bias slightly toward assigned queen wasp so the swarm splits into twin flowing streams.
                let eff_d2 = select(dist2, dist2 * 0.55, j_local == pref_wasp);
                if (eff_d2 < best_wasp_d2) {
                    best_wasp_d2 = eff_d2;
                    wasp_chase = nb.p.xyz - pos;
                }
                continue;
            }

            if (dist2 < sep_r2 && dist2 > 1e-7) {
                let inv_d = inverseSqrt(dist2);
                let dist = 1.0 / inv_d;
                let k = clamp(1.0 - dist / spec.sep_r, 0.0, 1.0);
                sep = sep + (d * inv_d) * (k * (0.7 + 0.6 * k));
            }
            if (dist2 < align_r2) {
                align = align + nb.v.xyz;
                n_align = n_align + 1.0;
            }
            if (dist2 < cohes_r2) {
                cohes = cohes + nb.p.xyz;
                n_cohes = n_cohes + 1.0;
            }
        }

        var steer = sep * spec.w_sep;
        if (n_align > 0.5) {
            steer = steer + safe_norm3(align / n_align, vel) * spec.w_align;
        }
        if (n_cohes > 0.5) {
            let center_dir = (cohes / n_cohes) - pos;
            steer = steer + clamp_len3(center_dir * 3.5, 1.0) * spec.w_cohes;
        }

        // Regime-specific goal / current field.
        if (arch == 0u) {
            // Pelagic Baitball: spacious hollow orbital swirl + dramatic radial predator scatter.
            let bait_c = vec3<f32>(0.05 * sin(phase * 0.45), 0.04 * cos(phase * 0.55), 0.0);
            let rel_c = pos - bait_c;
            let r_ball = max(length(rel_c), 1e-4);
            let tang = vec3<f32>(-rel_c.y, rel_c.x, 0.18 * sin(phase * 0.7 + f32(local_id)));
            let shell_pull = (0.19 - r_ball) * 2.2;
            steer = steer + (safe_norm3(rel_c, vec3<f32>(1.0, 0.0, 0.0)) * shell_pull + safe_norm3(tang, vec3<f32>(1.0, 0.0, 0.0)) * 0.90) * spec.w_goal;
            if (flee_strength > 0.01) {
                steer = steer + flee_vec * 2.6;
                turn_rate = mix(turn_rate, 11.5, flee_strength);
                speed_max = mix(speed_max, 1.30, flee_strength);
                flash = max(flash, flee_strength);
            }
        } else if (arch == 1u) {
            // Reef Ribbon Current: stagger fish along twin sinuous figure-8 splines for long flowing streams.
            let branch = local_id % 2u;
            let rank_u = f32(local_id) / max(f32(agents_per), 1.0);
            let lag = rank_u * 6.8;
            let s_cur = phase - lag;
            let p_tgt = ribbon_target(s_cur + 0.30, school_id, gen, is_narrow, branch);
            let p_ahead = ribbon_target(s_cur + 0.45, school_id, gen, is_narrow, branch);
            let flow_dir = safe_norm3(p_ahead - p_tgt, vec3<f32>(1.0, 0.0, 0.0));
            let to_spline = p_tgt - pos;
            steer = steer + (clamp_len3(to_spline * 4.5, 1.35) + flow_dir * 0.95) * spec.w_goal;
        } else if (arch == 2u) {
            // Wasp & Firefly Swarm: snap toward assigned wasp with orbital curl for wide comet arcs.
            let j_off = vec3<f32>(
                sin(phase * 2.6 + f32(local_id) * 1.7),
                cos(phase * 2.3 + f32(local_id) * 2.1),
                sin(phase * 2.0 - f32(local_id) * 1.3),
            ) * 0.095;
            let swirl = safe_norm3(vec3<f32>(-wasp_chase.y, wasp_chase.x, wasp_chase.z * 0.3), vec3<f32>(0.0, 1.0, 0.0));
            steer = steer + (safe_norm3(wasp_chase + j_off, vel) * 0.85 + swirl * 0.35) * spec.w_goal;
            let near_w = smoothstep(0.16, 0.02, sqrt(max(best_wasp_d2, 0.0)));
            flash = max(flash, near_w * 0.80);
        } else {
            // Abyssal Torus Vortex: evenly spaced 3D torus swirl + predator parting surge.
            let tilt = 0.30 * sin(phase * 0.18 + f32(school_id));
            let local_p = rotate_3d(pos, tilt, tilt * 0.6, 0.0);
            let r_xy = max(length(local_p.xy), 1e-4);
            let ring_r = 0.21;
            let rad_dir = vec3<f32>(local_p.xy / r_xy, 0.0);
            let tang_dir = vec3<f32>(-rad_dir.y, rad_dir.x, 0.0);
            let torus_force_local = rad_dir * ((ring_r - r_xy) * 5.2)
                + tang_dir * 1.45
                + vec3<f32>(0.0, 0.0, -local_p.z * 4.5);
            let torus_force = rotate_3d(torus_force_local, -tilt, -tilt * 0.6, 0.0);
            steer = steer + torus_force * spec.w_goal;
            if (flee_strength > 0.01) {
                steer = steer + flee_vec * 2.2;
                turn_rate = mix(turn_rate, 10.0, flee_strength);
                speed_max = mix(speed_max, 1.24, flee_strength);
                flash = max(flash, flee_strength * 0.9);
            }
        }

        // Smooth soft ellipsoid containment keeps schools cohesive inside the frame.
        let ellip = pos / vec3<f32>(spec.bound_xy, spec.bound_xy * 0.72, spec.bound_z);
        let r_ell = length(ellip);
        if (r_ell > 0.86) {
            let push = (r_ell - 0.86) * 3.6;
            steer = steer - safe_norm3(ellip, vec3<f32>(0.0)) * push;
        }

        let target_spd = mix(speed_min, speed_max, clamp(0.45 + 0.55 * flee_strength, 0.0, 1.0));
        let desired_v = safe_norm3(steer, safe_norm3(vel, vec3<f32>(1.0, 0.0, 0.0))) * target_spd;

        // Swarm uses inertial acceleration (classic XSwarm overshoot), fish use crisp turn-rate steering.
        if (arch == 2u) {
            let accel = (desired_v - vel) * 3.0;
            v_new = vel + accel * dt;
            v_new = v_new * exp(-0.28 * dt);
        } else {
            let k_blend = 1.0 - exp(-turn_rate * dt);
            let bank = length(desired_v - vel);
            flash = max(flash, clamp(bank * 0.58, 0.0, 0.68));
            v_new = mix(vel, desired_v, k_blend);
        }
    }

    // Clamp velocity cleanly inside [speed_min, speed_max].
    let spd_new = length(v_new);
    if (spd_new < speed_min) {
        v_new = safe_norm3(v_new, vec3<f32>(1.0, 0.0, 0.0)) * speed_min;
    } else if (spd_new > speed_max) {
        v_new = v_new * (speed_max / spd_new);
    }

    p_new = pos + v_new * dt;
    // Soft safety bounce against outer bounds.
    let hard_lim = vec3<f32>(spec.bound_xy * 1.15, spec.bound_xy * 0.84, spec.bound_z * 1.25);
    if (abs(p_new.x) > hard_lim.x) {
        p_new.x = clamp(p_new.x, -hard_lim.x, hard_lim.x);
        v_new.x = -v_new.x * 0.65;
    }
    if (abs(p_new.y) > hard_lim.y) {
        p_new.y = clamp(p_new.y, -hard_lim.y, hard_lim.y);
        v_new.y = -v_new.y * 0.65;
    }
    if (abs(p_new.z) > hard_lim.z) {
        p_new.z = clamp(p_new.z, -hard_lim.z, hard_lim.z);
        v_new.z = -v_new.z * 0.65;
    }

    let final_spd = length(v_new);
    swim_phase = (swim_phase + (6.8 + final_spd * 12.0) * dt) % TAU;

    if (!all(p_new == p_new) || !all(v_new == v_new)) {
        let sp = spawn_agent(arch, pal_id, spec, school_id, local_id, agents_per, gen, is_narrow);
        particles[write_base + agent_id] = sp;
        return;
    }

    var next_st: Particle;
    next_st.p = vec4<f32>(p_new, clamp(flash, 0.0, 1.0));
    next_st.v = vec4<f32>(v_new, swim_phase);
    next_st.c = vec4<f32>(col, packed_now);
    particles[write_base + agent_id] = next_st;

    if (arch == 2u) {
        splat_swarm(school_cm, p_new, pos, v_new, col, next_st.p.w, is_wasp, school_id, gen, phase, env, a);
    } else {
        splat_fish(school_cm, p_new, pos, v_new, col, swim_phase, next_st.p.w, is_pred, school_id, gen, phase, env, a);
    }
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    let dims = splat_dims();
    let duv = vec2<f32>(DRIFT_VX * g.dt / aspect(), 0.0);
    let base_uv = uv - duv;
    var prev = state_sample(base_uv);
    if (dims.y >= 180) {
        let tex = state_texel();
        let blur = (
            state_sample(base_uv + vec2<f32>(tex.x, 0.0))
            + state_sample(base_uv - vec2<f32>(tex.x, 0.0))
            + state_sample(base_uv + vec2<f32>(0.0, tex.y))
            + state_sample(base_uv - vec2<f32>(0.0, tex.y))
        ) * 0.25;
        let diff = clamp(g.dt * 7.5, 0.0, 0.22);
        prev = mix(prev, blur, diff);
    }

    // Step vacated solid interiors down swiftly into silky liquid wakes while preserving faint wake trails.
    let drop_scale = clamp(g.dt / 0.01667, 0.25, 2.5);
    let wake_drop = mix(1.0, pow(0.32, drop_scale), clamp(prev.a, 0.0, 1.0));
    let wake = prev.rgb * (g.fade * wake_drop);

    let body_cov = clamp(splat.a, 0.0, 1.0);
    let body_rgb = splat.rgb / max(splat.a, 1.0);
    let out_rgb = wake * (1.0 - body_cov * 0.85) + body_rgb;
    return vec4<f32>(out_rgb, body_cov);
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    let s = state_sample(uv);
    let d = state_texel();

    let h_card = state_sample(uv + vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv - vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.4))
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.4));
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.4, d.y * 2.4))
        + state_sample(uv + vec2<f32>(-d.x * 2.4, d.y * 2.4))
        + state_sample(uv + vec2<f32>(d.x * 2.4, -d.y * 2.4))
        + state_sample(uv + vec2<f32>(-d.x * 2.4, -d.y * 2.4));
    let halo = (h_card + h_diag) * 0.125;

    let raw_rgb = max(s.rgb + halo.rgb * 0.26, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4 && s.a <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // Chromaticity-preserving exponential tone mapping keeps bioluminescent schools crisp and saturated.
    let mapped_lum = 1.0 - exp(-peak_c * 1.60);
    let out_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}
