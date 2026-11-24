// Fluid Beads: luminous fluid beads sloshing, colliding and cascading through
// tilting gravity chambers across the dark on Tier P compute particles and
// advected Tier S feedback textures.
// After xscreensaver's Fluidballs (Peter Birtles and Jamie Zawinski).
//
// Race-free Jacobi ping-pong particle buffer (`Particles { count: 576 }`):
//   Half 0 (`0..287`) and Half 1 (`288..575`) alternate as read/write halves
//   according to `u32(round(max(g.frame, 0.0))) & 1u`.
//
// Particle layout (`particles[idx]`):
//   p.xy  = chamber-local 2D position (canvas heights)
//   p.z   = bead radius in canvas heights
//   p.w   = kinetic impact flash energy (0..1)
//   v.xy  = chamber-local 2D velocity (canvas heights/sec)
//   v.z   = mass / buoyancy factor
//   v.w   = spin angle (radians)
//   c.rgb = jewel base RGB color
//   c.w   = packed epoch `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninitialized)

const MAX_BALLS: u32 = 288u;
const DRIFT_VX: f32 = 0.160;
const EPOCH_SECS: f32 = 34.0;
const MAX_SPEED: f32 = 1.35;

struct ChamberSpec {
    half_size: vec2<f32>,
    is_drum: bool,
    drum_r: f32,
    restitution: f32,
    viscosity: f32,
    xsph: f32,
    wall_restitution: f32,
};

fn clamp_len(v: vec2<f32>, max_l: f32) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 > max_l * max_l && l2 > 1e-12) {
        return v * (max_l * inverseSqrt(l2));
    }
    return v;
}

fn chamber_spec(arch: u32, is_narrow: bool) -> ChamberSpec {
    let sx = select(1.0, 0.87, is_narrow);
    if (arch == 0u) {
        // Tumbling Wave Tank (Shake Box)
        return ChamberSpec(vec2<f32>(0.44 * sx, 0.34), false, 0.0, 0.44, 0.16, 0.36, 0.50);
    }
    if (arch == 1u) {
        // Churning Tide Drum
        let dr = select(0.39, 0.35, is_narrow);
        return ChamberSpec(vec2<f32>(dr, dr), true, dr, 0.38, 0.20, 0.42, 0.46);
    }
    if (arch == 2u) {
        // Buoyant Fountain & Cascade
        return ChamberSpec(vec2<f32>(0.43 * sx, 0.37), false, 0.0, 0.50, 0.12, 0.28, 0.55);
    }
    // Elastic Gas & Convective Arena
    return ChamberSpec(vec2<f32>(0.44 * sx, 0.35), false, 0.0, 0.94, 0.02, 0.04, 0.95);
}

// Four curated jewel palettes with balanced R/G/B coverage across size classes.
fn bead_palette(pal: u32, class_id: u32) -> vec3<f32> {
    let p = pal % 4u;
    let c = class_id % 4u;
    if (p == 0u) {
        // Reef Bioluminescence
        if (c == 0u) {
            return vec3<f32>(0.12, 0.88, 1.00);
        }
        if (c == 1u) {
            return vec3<f32>(1.00, 0.28, 0.22);
        }
        if (c == 2u) {
            return vec3<f32>(0.16, 0.96, 0.58);
        }
        return vec3<f32>(0.48, 0.34, 1.00);
    }
    if (p == 1u) {
        // Molten Amethyst
        if (c == 0u) {
            return vec3<f32>(1.00, 0.66, 0.14);
        }
        if (c == 1u) {
            return vec3<f32>(0.98, 0.22, 0.64);
        }
        if (c == 2u) {
            return vec3<f32>(0.14, 0.88, 0.82);
        }
        return vec3<f32>(0.42, 0.38, 1.00);
    }
    if (p == 2u) {
        // Emerald Tide
        if (c == 0u) {
            return vec3<f32>(0.14, 0.95, 0.46);
        }
        if (c == 1u) {
            return vec3<f32>(0.18, 0.66, 1.00);
        }
        if (c == 2u) {
            return vec3<f32>(1.00, 0.44, 0.16);
        }
        return vec3<f32>(0.76, 0.32, 0.98);
    }
    // Prism Marbles
    if (c == 0u) {
        return vec3<f32>(1.00, 0.20, 0.34);
    }
    if (c == 1u) {
        return vec3<f32>(0.58, 0.96, 0.18);
    }
    if (c == 2u) {
        return vec3<f32>(0.16, 0.82, 1.00);
    }
    return vec3<f32>(0.62, 0.30, 1.00);
}

fn chamber_center(chamber_id: u32, n_chambers: u32, gen: u32, t: f32) -> vec2<f32> {
    let a = aspect();
    let fc = f32(chamber_id);
    let fg = f32(gen);
    let jx = (hash11(fc * 19.7 + fg * 31.3 + g.seed * 59.0) - 0.5) * 0.12;
    let x0 = fract((fc + 0.5 + jx) / f32(n_chambers) + g.seed * 0.41) * a;
    let y_base = 0.40 + 0.22 * fract(0.23 + fc * 0.47 + fg * 0.618034 + g.seed * 0.53);
    let y_sway = 0.080 * sin(t * 0.29 + fc * 2.1 + fg * 1.3);
    return vec2<f32>(
        fract((x0 + DRIFT_VX * t) / a) * a,
        clamp(y_base + y_sway, 0.38, 0.64),
    );
}

fn chamber_angle(arch: u32, chamber_id: u32, gen: u32, phase: f32) -> f32 {
    let fc = f32(chamber_id);
    let fg = f32(gen);
    let ph0 = hash11(fc * 13.7 + fg * 29.1 + g.seed * 41.0) * TAU;
    if (arch == 0u) {
        // Continuous wave rocking with smooth 180-degree overturns every 6.8s.
        let turn_u = phase / 6.8;
        let turn_i = floor(turn_u);
        let turn_f = turn_u - turn_i;
        let flip = (turn_i + smoothstep(0.24, 0.76, turn_f)) * PI;
        let rock = 0.40 * sin(phase * 1.45 + ph0);
        return flip + rock;
    }
    if (arch == 1u) {
        return 0.0;
    }
    if (arch == 2u) {
        return 0.22 * sin(phase * 0.88 + ph0);
    }
    return 0.18 * sin(phase * 0.52 + ph0);
}

fn chamber_accel(
    arch: u32,
    spec: ChamberSpec,
    box_ang: f32,
    chamber_id: u32,
    gen: u32,
    phase: f32,
    pos: vec2<f32>,
    vel: vec2<f32>,
    density: f32,
) -> vec2<f32> {
    let fc = f32(chamber_id);
    let fg = f32(gen);
    let ph0 = hash11(fc * 17.3 + fg * 23.9 + g.seed * 37.0) * TAU;

    if (arch == 0u) {
        // World gravity rotated into tilting box space + brisk slosh impulses.
        var grav = rot2(-box_ang) * vec2<f32>(0.0, -1.65);
        let shake_u = fract(phase / 4.2);
        let shake_env = exp(-pow((shake_u - 0.5) * 7.5, 2.0));
        let shake_x = sin(phase * 9.5 + ph0) * 1.90 * shake_env;
        grav.x = grav.x + shake_x;
        return grav * mix(0.84, 1.14, clamp((density - 0.70) / 0.65, 0.0, 1.0));
    }

    if (arch == 1u) {
        // Rotating gravity + orbiting internal paddle scooping fluid into breakers.
        let g_ang = phase * 0.74 + ph0;
        var acc = vec2<f32>(sin(g_ang), -cos(g_ang)) * 1.45;
        let pad_w = -phase * 2.15 + ph0;
        let pad_pos = vec2<f32>(cos(pad_w), sin(pad_w)) * (spec.drum_r * 0.56);
        let pad_tang = vec2<f32>(-sin(pad_w), cos(pad_w));
        let to_pad = pos - pad_pos;
        let d_pad = length(to_pad);
        if (d_pad < 0.19) {
            let k = smoothstep(0.19, 0.02, d_pad);
            let push_dir = normalize(to_pad + vec2<f32>(1e-4, 2e-4));
            acc = acc + push_dir * (3.8 * k) + pad_tang * (3.2 * k);
        }
        return acc;
    }

    if (arch == 2u) {
        // Rocking gravity + wide counter-sweeping floor geysers + gentle convective draw toward jets.
        var acc = rot2(-box_ang) * vec2<f32>(0.0, -1.65);
        let floor_y = -spec.half_size.y;
        let j1_x = spec.half_size.x * 0.54 * sin(phase * 0.92 + ph0);
        let j2_x = -spec.half_size.x * 0.54 * sin(phase * 0.92 + ph0 + 0.9);
        let h_norm = clamp((pos.y - floor_y) / 0.34, 0.0, 1.0);
        let y_gate = 1.0 - h_norm * h_norm;
        if (y_gate > 0.01) {
            let d1 = abs(pos.x - j1_x);
            let d2 = abs(pos.x - j2_x);
            let w1 = exp(-(d1 * d1) / (0.13 * 0.13)) * y_gate;
            let w2 = exp(-(d2 * d2) / (0.13 * 0.13)) * y_gate;
            let fan1 = (pos.x - j1_x) * 4.8 + 0.55 * cos(phase * 2.1 + ph0);
            let fan2 = (pos.x - j2_x) * 4.8 - 0.55 * sin(phase * 1.9 + ph0);
            acc = acc + vec2<f32>(fan1 * w1 + fan2 * w2, 6.2 * (w1 + w2));
            // Gentle bottom floor return sweep guides pooled beads back under the jets.
            if (pos.y < floor_y + 0.12) {
                let near_j = select(j2_x, j1_x, d1 < d2);
                acc.x = acc.x + clamp((near_j - pos.x) * 3.0, -1.2, 1.2);
            }
        }
        acc.y = acc.y + (1.0 - density) * 0.52;
        return acc;
    }

    // Elastic Gas & Convective Arena: mild rotating gravity + dual-eddy convective current + soft centering.
    let g_ang = phase * 0.42 + ph0;
    var acc = vec2<f32>(sin(g_ang), -cos(g_ang)) * 0.34;
    let eddy_x = sin(pos.y * 7.2 + phase * 1.15 + ph0);
    let eddy_y = cos(pos.x * 6.5 - phase * 0.95 + ph0);
    acc = acc + vec2<f32>(eddy_x, eddy_y) * 0.48;
    // Soft inward restoring tether keeps gas molecules filling the center instead of hugging walls.
    acc = acc - pos * 0.95;
    let spd = length(vel);
    let target_spd = 0.56;
    if (spd > 1e-4) {
        acc = acc + (vel / spd) * clamp((target_spd - spd) * 1.45, -0.45, 0.70);
    }
    return acc;
}

fn clamp_to_chamber(
    pos_in: vec2<f32>,
    vel_in: vec2<f32>,
    r: f32,
    spec: ChamberSpec,
) -> vec4<f32> {
    var p = pos_in;
    var v = vel_in;

    if (spec.is_drum) {
        let max_r = max(spec.drum_r - r, 0.02);
        let d = length(p);
        if (d > max_r && d > 1e-5) {
            let n = p / d;
            p = n * max_r;
            let vn = dot(v, n);
            if (vn > 0.0) {
                v = v - (1.0 + spec.wall_restitution) * vn * n;
                let t_vec = vec2<f32>(-n.y, n.x);
                v = v - t_vec * (dot(v, t_vec) * 0.05);
            }
        }
        return vec4<f32>(p, v);
    }

    let bound = max(spec.half_size - vec2<f32>(r), vec2<f32>(0.02));
    if (p.x < -bound.x) {
        p.x = -bound.x;
        if (v.x < 0.0) {
            v.x = -v.x * spec.wall_restitution;
            v.y = v.y * 0.95;
        }
    } else if (p.x > bound.x) {
        p.x = bound.x;
        if (v.x > 0.0) {
            v.x = -v.x * spec.wall_restitution;
            v.y = v.y * 0.95;
        }
    }
    if (p.y < -bound.y) {
        p.y = -bound.y;
        if (v.y < 0.0) {
            v.y = -v.y * spec.wall_restitution;
            v.x = v.x * 0.95;
        }
    } else if (p.y > bound.y) {
        p.y = bound.y;
        if (v.y > 0.0) {
            v.y = -v.y * spec.wall_restitution;
            v.x = v.x * 0.95;
        }
    }
    return vec4<f32>(p, v);
}

fn spawn_bead(
    arch: u32,
    pal_id: u32,
    spec: ChamberSpec,
    chamber_id: u32,
    local_id: u32,
    balls_per: u32,
    gen: u32,
) -> Particle {
    let fl = f32(local_id);
    let fc = f32(chamber_id);
    let fg = f32(gen);
    let h0 = hash22(vec2<f32>(fl * 1.73 + fc * 17.3, fg * 31.7 + g.seed * 67.0));
    let h1 = hash22(vec2<f32>(fl * 2.91 + fg * 19.3, fc * 41.1 + g.seed * 53.0));

    let class_id = local_id % 4u;
    var r = 0.020;
    var density = 1.0;
    if (class_id == 0u) {
        r = 0.025 + 0.004 * h0.x;
        density = 1.25;
    } else if (class_id == 1u) {
        r = 0.021 + 0.003 * h0.x;
        density = 1.05;
    } else if (class_id == 2u) {
        r = 0.017 + 0.003 * h0.x;
        density = 0.90;
    } else {
        r = 0.014 + 0.002 * h0.x;
        density = 0.75;
    }

    // Golden-angle spiral or grid placement keeps initial beads separated inside every chamber.
    let u = (fl + 0.5) / max(f32(balls_per), 1.0);
    let ang = fl * 2.3999632 + h0.y * 0.35 + fc * 1.7;
    var pos = vec2<f32>(0.0);
    if (spec.is_drum) {
        let rr = sqrt(u) * max(spec.drum_r - r * 1.6, 0.05);
        pos = vec2<f32>(cos(ang), sin(ang)) * rr;
    } else {
        let cols = max(floor(sqrt(f32(balls_per) * 1.25)), 4.0);
        let rows = ceil(f32(balls_per) / cols);
        let gx = (fl % cols + 0.5 + (h0.x - 0.5) * 0.45) / cols * 2.0 - 1.0;
        let gy = (floor(fl / cols) + 0.5 + (h0.y - 0.5) * 0.45) / max(rows, 1.0) * 2.0 - 1.0;
        let bound = max(spec.half_size - vec2<f32>(r * 1.6), vec2<f32>(0.05));
        pos = vec2<f32>(gx * bound.x * 0.92, gy * bound.y * 0.92);
    }

    var vel = vec2<f32>((h1.x - 0.5) * 0.55, (h1.y - 0.5) * 0.55);
    if (arch == 0u || arch == 1u) {
        vel = vel + vec2<f32>(-pos.y, pos.x) * 1.15;
    } else if (arch == 2u) {
        vel = vel + vec2<f32>(pos.x * 0.4, 0.35 + 0.25 * h1.y);
    } else {
        let dir = normalize(vec2<f32>(cos(ang + 1.2), sin(ang + 1.2)));
        vel = dir * (0.42 + 0.24 * h1.x);
    }

    let col = bead_palette(pal_id, class_id);
    var out: Particle;
    out.p = vec4<f32>(pos, r, 0.25);
    out.v = vec4<f32>(vel, density, h0.y * TAU);
    out.c = vec4<f32>(col, f32((gen % 16777215u) + 1u));
    return out;
}

fn splat_bead(
    world_p: vec2<f32>,
    r: f32,
    col: vec3<f32>,
    impact_e: f32,
    spin: f32,
    env: f32,
) {
    if (env <= 0.003) {
        return;
    }
    let y_clip = smoothstep(0.015, 0.06, world_p.y) * (1.0 - smoothstep(0.94, 0.985, world_p.y));
    let alpha_env = env * y_clip;
    if (alpha_env <= 0.003) {
        return;
    }

    let dims = splat_dims();
    let uv = state_uv(world_p);
    let center_px = uv * vec2<f32>(dims) - 0.5;
    let px_r = r * f32(dims.y);
    let ir = clamp(i32(ceil(px_r + 1.2)), 1, 22);
    let base = vec2<i32>(round(center_px));
    let inv_r = 1.0 / max(px_r, 0.5);

    // Subsurface caustic orientation tilts slightly with bead spin while specular stays locked to key light.
    let ca_s = 0.22 * sin(spin);
    let ca_c = 0.22 * cos(spin);
    let caus_dir = normalize(vec2<f32>(0.52 + ca_s * 0.25, -0.58 + ca_c * 0.25));
    let spec_dir = normalize(vec2<f32>(-0.46, 0.52));

    for (var dy = -ir; dy <= ir; dy = dy + 1) {
        let cy = base.y + dy;
        if (cy < 0 || cy >= dims.y) {
            continue;
        }
        // Screen +Y is up while texel y runs downward.
        let rel_y = center_px.y - f32(cy);
        for (var dx = -ir; dx <= ir; dx = dx + 1) {
            let cx = base.x + dx;
            let rel_x = f32(cx) - center_px.x;
            let d_px = length(vec2<f32>(rel_x, rel_y));
            if (d_px > px_r + 0.85) {
                continue;
            }
            let cov = (1.0 - smoothstep(max(px_r - 0.65, 0.0), px_r + 0.65, d_px)) * alpha_env;
            if (cov <= 0.002) {
                continue;
            }

            let u_xy = clamp_len(vec2<f32>(rel_x, rel_y) * inv_r, 0.995);
            let nz = sqrt(max(1.0 - dot(u_xy, u_xy), 0.0));

            // 3D liquid glass sphere shading: deep translucent jewel body, luminous Fresnel rim,
            // refracted bottom-right caustic crescent and sharp top-left specular glint.
            let fres = pow(1.0 - nz, 2.05);
            let caus_dot = max(dot(u_xy, caus_dir), 0.0);
            let caus = pow(caus_dot, 2.8) * (0.42 + 0.58 * (1.0 - nz));
            let spec_d = length(u_xy - spec_dir);
            let spec = exp(-(spec_d * spec_d) / (0.14 * 0.14));
            let body = 0.14 + 0.18 * nz;

            var shaded = col * (body + fres * 1.18)
                + mix(col, vec3<f32>(1.0), 0.40) * (caus * 0.78)
                + mix(col, vec3<f32>(1.0, 0.98, 0.94), 0.74) * (spec * 1.05);

            // Kinetic collision shimmer brightens rim and subsurface core briefly on impact.
            shaded = shaded + mix(col, vec3<f32>(1.0, 0.97, 0.92), 0.48) * (impact_e * (0.34 + 0.48 * fres));
            shaded = clamp(shaded, vec3<f32>(0.0), vec3<f32>(1.50));

            let wx = ((cx % dims.x) + dims.x) % dims.x;
            splat_pixel(vec2<i32>(wx, cy), vec4<f32>(shaded * cov, cov));
        }
    }
}

fn step_particle(idx: u32, t: f32) {
    let frame_u = u32(round(max(g.frame, 0.0)));
    let write_half = frame_u & 1u;
    let read_half = 1u - write_half;
    let read_base = read_half * MAX_BALLS;
    let write_base = write_half * MAX_BALLS;

    if (idx < write_base || idx >= write_base + MAX_BALLS) {
        return;
    }

    let ball_id = idx - write_base;
    let a = aspect();
    let is_narrow = a < 2.4;
    let n_chambers = select(3u, 2u, is_narrow);
    let balls_per = select(96u, 72u, is_narrow);
    if (ball_id >= n_chambers * balls_per) {
        return;
    }

    let chamber_id = ball_id / balls_per;
    let local_id = ball_id % balls_per;
    let fc = f32(chamber_id);
    let chamber_off = (fc / f32(n_chambers) + 0.13 * hash11(fc * 19.3 + g.seed * 41.0)) * EPOCH_SECS;

    let cycle_t = t + chamber_off;
    let gen = u32(max(floor(cycle_t / EPOCH_SECS), 0.0));
    let phase = cycle_t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.07, u_epoch) * (1.0 - smoothstep(0.92, 1.0, u_epoch));

    let arch = (gen + chamber_id + u32(g.seed * 13.0)) % 4u;
    let pal_id = (gen * 3u + chamber_id * 2u + u32(g.seed * 17.0)) % 4u;
    let spec = chamber_spec(arch, is_narrow);
    let box_ang = chamber_angle(arch, chamber_id, gen, phase);
    let chamber_cm = chamber_center(chamber_id, n_chambers, gen, t + g.dt);

    let st = particles[read_base + ball_id];
    let packed_now = f32((gen % 16777215u) + 1u);
    let uninit = g.frame < 0.5
        || st.c.w <= 0.5
        || abs(st.c.w - packed_now) > 0.5
        || !all(st.p.xyz == st.p.xyz)
        || !all(st.v.xyz == st.v.xyz);

    if (uninit) {
        let sp = spawn_bead(arch, pal_id, spec, chamber_id, local_id, balls_per, gen);
        particles[write_base + ball_id] = sp;
        let wp = chamber_cm + rot2(box_ang) * sp.p.xy;
        let wrap_p = vec2<f32>(fract(wp.x / a) * a, wp.y);
        splat_bead(wrap_p, sp.p.z, sp.c.rgb, sp.p.w, sp.v.w, env);
        return;
    }

    let dt = clamp(g.dt, 1e-4, 0.12);
    var p = st.p.xy;
    let ri = st.p.z;
    var impact_e = st.p.w * exp(-dt * 4.5);
    var v = st.v.xy;
    let density = max(st.v.z, 0.4);
    var spin = st.v.w;
    let col = st.c.rgb;
    let mi = ri * ri * density;

    let acc = chamber_accel(arch, spec, box_ang, chamber_id, gen, phase, p, v, density);
    v = clamp_len(v + acc * dt, MAX_SPEED);
    let p_pred = p + v * dt;

    var corr = vec2<f32>(0.0);
    var dv = vec2<f32>(0.0);
    var v_xsph = vec2<f32>(0.0);
    var hit_count = 0.0;
    var spin_kick = 0.0;

    let chamber_base = read_base + chamber_id * balls_per;
    let det_seed = f32(local_id) * 0.73 + f32(frame_u % 97u) * 0.19;

    for (var j_local = 0u; j_local < balls_per; j_local = j_local + 1u) {
        if (j_local == local_id) {
            continue;
        }
        let nb = particles[chamber_base + j_local];
        if (nb.c.w <= 0.5 || abs(nb.c.w - packed_now) > 0.5 || !all(nb.p.xyz == nb.p.xyz)) {
            continue;
        }
        let rj = nb.p.z;
        let min_d = ri + rj;
        let smooth_r = min_d * 1.65;
        let pj_pred = nb.p.xy + nb.v.xy * dt;
        let dvec = p_pred - pj_pred;
        let dist2 = dot(dvec, dvec);
        if (dist2 >= smooth_r * smooth_r) {
            continue;
        }
        let dist = sqrt(max(dist2, 0.0));
        let mj = rj * rj * max(nb.v.z, 0.4);
        let w_i = mj / max(mi + mj, 1e-6);

        if (dist < min_d) {
            var n = vec2<f32>(cos(det_seed + f32(j_local)), sin(det_seed + f32(j_local)));
            if (dist > 1e-4) {
                n = dvec / dist;
            }
            let pen = min_d - dist;
            corr = corr + n * (pen * w_i);
            hit_count = hit_count + 1.0;

            let rel_v = v - nb.v.xy;
            let vn = dot(rel_v, n);
            if (vn < 0.0) {
                let imp_n = -(1.0 + spec.restitution) * vn * w_i;
                let t_vec = vec2<f32>(-n.y, n.x);
                let vt = dot(rel_v, t_vec);
                dv = dv + n * imp_n - t_vec * (vt * spec.viscosity * w_i);
                spin_kick = spin_kick + vt * 0.45 * w_i;
                impact_e = max(impact_e, clamp(-vn * 1.1, 0.0, 1.0));
            }
        }

        // XSPH fluid velocity cohesion + gentle short-range fluid repulsion.
        let q = clamp(1.0 - dist / smooth_r, 0.0, 1.0);
        v_xsph = v_xsph + (nb.v.xy - v) * (q * q);
    }

    let relax = 1.0 / (1.0 + 0.65 * max(hit_count - 1.0, 0.0));
    let corr_scaled = clamp_len(corr * (0.72 * relax), 0.85 * ri);
    let dv_scaled = clamp_len(dv * (0.85 * relax), 1.50);
    let pbd_vel = clamp_len(corr * (0.30 * relax / max(dt, 0.016)), 0.35);

    var p_new = p_pred + corr_scaled;
    var v_new = v + dv_scaled + v_xsph * (spec.xsph * dt) + pbd_vel;
    v_new = v_new * exp(-0.08 * dt);

    // Measure wall impact before clamping so boundary bounces also flash subtly.
    let pre_clamp_v = v_new;
    let clamped = clamp_to_chamber(p_new, v_new, ri, spec);
    p_new = clamped.xy;
    v_new = clamped.zw;
    let wall_dv = length(v_new - pre_clamp_v);
    if (wall_dv > 0.05) {
        impact_e = max(impact_e, clamp(wall_dv * 0.85, 0.0, 1.0));
    }

    v_new = clamp_len(v_new, MAX_SPEED);
    spin = spin + (spin_kick + length(v_new) * 1.4 * select(-1.0, 1.0, (local_id & 1u) == 0u)) * dt;

    if (!all(p_new == p_new) || !all(v_new == v_new)) {
        let sp = spawn_bead(arch, pal_id, spec, chamber_id, local_id, balls_per, gen);
        particles[write_base + ball_id] = sp;
        return;
    }

    var next_st: Particle;
    next_st.p = vec4<f32>(p_new, ri, clamp(impact_e, 0.0, 1.0));
    next_st.v = vec4<f32>(v_new, density, spin);
    next_st.c = vec4<f32>(col, packed_now);
    particles[write_base + ball_id] = next_st;

    let wp = chamber_cm + rot2(box_ang) * p_new;
    let wrap_p = vec2<f32>(fract(wp.x / a) * a, wp.y);
    splat_bead(wrap_p, ri, col, next_st.p.w, spin, env);
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
        let diff = clamp(g.dt * 10.0, 0.0, 0.34);
        prev = mix(prev, blur, diff);
    }

    // Step vacated bead interiors down sharply so moving beads leave a soft liquid shimmer instead of stepped rings.
    let wake_drop = mix(0.76, 0.11, clamp(prev.a, 0.0, 1.0));
    let wake = prev.rgb * (g.fade * wake_drop);

    let ball_cov = clamp(splat.a, 0.0, 1.0);
    let ball_rgb = splat.rgb / max(splat.a, 1.0);
    let out_rgb = wake * (1.0 - ball_cov) + ball_rgb;
    return vec4<f32>(out_rgb, ball_cov);
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

    let raw_rgb = max(s.rgb + halo.rgb * 0.25, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4 && s.a <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // Chromaticity-preserving exponential tone mapping keeps jewel hues vivid across overlapping clusters.
    let mapped_lum = 1.0 - exp(-peak_c * 1.65);
    let out_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}
