// Fluid Beads: luminous fluid beads sloshing, colliding and cascading across
// a stationary full-canvas tank on Tier P compute particles and Tier S feedback
// textures.
// After xscreensaver's Fluidballs (Peter Birtles and Jamie Zawinski).
//
// Race-free Jacobi ping-pong particle buffer (`Particles { count: 576 }`):
//   Half 0 (`0..287`) and Half 1 (`288..575`) alternate as read/write halves
//   according to `u32(round(max(g.frame, 0.0))) & 1u`.
//
// Particle layout (`particles[idx]`):
//   p.xy  = full-canvas 2D position (canvas heights: x in 0..aspect(), y in 0..1)
//   p.z   = bead radius in canvas heights
//   p.w   = kinetic impact flash energy (0..1)
//   v.xy  = full-canvas 2D velocity (canvas heights/sec)
//   v.z   = mass / buoyancy factor
//   v.w   = spin angle (radians)
//   c.rgb = jewel base RGB color
//   c.w   = packed epoch `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninitialized)

const MAX_BALLS: u32 = 288u;
const EPOCH_SECS: f32 = 34.0;
const MAX_SPEED: f32 = 1.45;
const TANK_PAD: f32 = 0.020;

struct TankSpec {
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

fn safe_norm2(v: vec2<f32>, fallback: vec2<f32>) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn reflect_range(x: f32, lo: f32, hi: f32) -> f32 {
    let span = max(hi - lo, 1e-4);
    let u = (x - lo) / span;
    let m = u - 2.0 * floor(u * 0.5);
    let f = select(2.0 - m, m, m <= 1.0);
    return lo + f * span;
}

fn next_iso_wp(
    cur: vec2<f32>,
    prev_ang: f32,
    step_idx: u32,
    seed_v: vec2<f32>,
    x_lo: f32,
    x_hi: f32,
    y_lo: f32,
    y_hi: f32,
    d_min: f32,
    d_max: f32,
) -> vec3<f32> {
    let r = hash22(seed_v + vec2<f32>(f32(step_idx) * 13.7, f32(step_idx) * 29.3));
    let ang = prev_ang + (r.x - 0.5) * 2.5;
    let step_d = mix(d_min, d_max, r.y);
    let cand = cur + vec2<f32>(cos(ang), sin(ang)) * step_d;
    var nxt = vec2<f32>(reflect_range(cand.x, x_lo, x_hi), reflect_range(cand.y, y_lo, y_hi));
    if (length(nxt - cur) < d_min * 0.55) {
        let cx = 0.5 * (x_lo + x_hi);
        let cy = 0.5 * (y_lo + y_hi);
        let inward = safe_norm2(
            vec2<f32>(cx - cur.x, cy - cur.y) + vec2<f32>(cos(ang), sin(ang)) * 0.35,
            vec2<f32>(1.0, 0.0),
        );
        nxt = vec2<f32>(
            clamp(cur.x + inward.x * step_d, x_lo, x_hi),
            clamp(cur.y + inward.y * step_d, y_lo, y_hi),
        );
    }
    let dp = nxt - cur;
    let next_ang = atan2(dp.y, dp.x);
    return vec3<f32>(nxt, next_ang);
}

fn catmull_rom2(p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>, p3: vec2<f32>, u: f32) -> vec2<f32> {
    let u2 = u * u;
    let u3 = u2 * u;
    return 0.5 * (
        (2.0 * p1)
        + (-p0 + p2) * u
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u2
        + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u3
    );
}

fn iso_waypoint_pos(
    p1_init: vec2<f32>,
    ang_init: f32,
    seed_v: vec2<f32>,
    s: f32,
    speed: f32,
    x_lo: f32,
    x_hi: f32,
    y_lo: f32,
    y_hi: f32,
    d_min: f32,
    d_max: f32,
    max_hops: u32,
) -> vec2<f32> {
    var p1 = p1_init;
    let w1 = next_iso_wp(p1, ang_init, 1u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p2 = w1.xy;
    let w2 = next_iso_wp(p2, w1.z, 2u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p3 = w2.xy;
    var cur_ang = w2.z;
    var p0 = p1 - (p2 - p1);
    var t_acc = 0.0;

    for (var k = 0u; k < max_hops; k = k + 1u) {
        let seg_dur = max(length(p2 - p1) / speed, 0.35);
        if (s <= t_acc + seg_dur || k + 1u == max_hops) {
            let u = clamp((s - t_acc) / seg_dur, 0.0, 1.0);
            let pos = catmull_rom2(p0, p1, p2, p3, u);
            return vec2<f32>(
                clamp(pos.x, x_lo - 0.05, x_hi + 0.05),
                clamp(pos.y, y_lo - 0.04, y_hi + 0.04),
            );
        }
        t_acc = t_acc + seg_dur;
        p0 = p1;
        p1 = p2;
        p2 = p3;
        let w_nxt = next_iso_wp(p2, cur_ang, k + 3u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
        p3 = w_nxt.xy;
        cur_ang = w_nxt.z;
    }
    return p1;
}

fn bezel_fade(p: vec2<f32>, a: f32) -> f32 {
    return smoothstep(0.012, 0.048, p.x)
        * (1.0 - smoothstep(a - 0.048, a - 0.012, p.x))
        * smoothstep(0.012, 0.048, p.y)
        * (1.0 - smoothstep(0.952, 0.988, p.y));
}

fn tank_spec(arch: u32) -> TankSpec {
    if (arch == 0u) {
        // Rolling Tidal Wave Tank
        return TankSpec(0.46, 0.14, 0.36, 0.56);
    }
    if (arch == 1u) {
        // Roaming Vortex Paddles
        return TankSpec(0.42, 0.16, 0.40, 0.54);
    }
    if (arch == 2u) {
        // Sweeping Alternating Geysers
        return TankSpec(0.52, 0.11, 0.28, 0.58);
    }
    // Elastic Convective Arena
    return TankSpec(0.93, 0.02, 0.04, 0.94);
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

fn tank_accel(
    arch: u32,
    gen: u32,
    phase: f32,
    pos: vec2<f32>,
    vel: vec2<f32>,
    density: f32,
    a: f32,
) -> vec2<f32> {
    let ph0 = hash11(f32(gen) * 23.9 + g.seed * 37.0) * TAU;

    // Gentle perimeter inward cushion (used gently in non-elastic liquid modes so beads never camp along bezels).
    let edge_l = smoothstep(TANK_PAD + 0.10, TANK_PAD + 0.005, pos.x);
    let edge_r = smoothstep(a - TANK_PAD - 0.10, a - TANK_PAD - 0.005, pos.x);
    let edge_b = smoothstep(TANK_PAD + 0.10, TANK_PAD + 0.005, pos.y);
    let edge_t = smoothstep(1.0 - TANK_PAD - 0.10, 1.0 - TANK_PAD - 0.005, pos.y);

    if (arch == 0u) {
        // Rolling Tidal Wave Tank: divergence-free slosh shear + traveling vertical swells across full width (zero corner trap).
        let shear_x = sin(pos.y * 3.1 - phase * 1.25 + ph0) * 0.92 + cos(pos.y * 1.9 + phase * 0.85) * 0.42;
        let swell_y = -1.05 * cos(pos.x * 1.95 - phase * 1.45 + ph0) - 0.36 * sin(phase * 0.90 + ph0);
        let shake_u = fract(phase / 4.2);
        let shake_env = exp(-pow((shake_u - 0.5) * 7.0, 2.0));
        let shake_x = sin(phase * 7.2 + pos.y * 2.6 + ph0) * 0.95 * shake_env;
        let dens_scale = mix(0.84, 1.14, clamp((density - 0.70) / 0.65, 0.0, 1.0));
        var acc = vec2<f32>(shear_x + shake_x, swell_y) * dens_scale;
        acc = acc + vec2<f32>(edge_l - edge_r, edge_b - edge_t) * 0.80;
        return acc;
    }

    if (arch == 1u) {
        // Roaming Vortex Paddles: mild cellular shear tide + balanced centripetal-whirlpool paddles + wall entrainment.
        let tide = vec2<f32>(
            sin(pos.y * 3.1 + phase * 0.82 + ph0),
            cos(pos.x * 2.2 - phase * 0.74 + ph0),
        ) * 0.36;
        var acc = tide + vec2<f32>(edge_l - edge_r, edge_b - edge_t) * 0.95;
        let n_paddles = select(3u, 2u, a < 2.4);
        for (var k = 0u; k < n_paddles; k = k + 1u) {
            let fk = f32(k);
            let h_k = hash22(vec2<f32>(fk * 17.3 + f32(gen) * 29.1, g.seed * 61.0 + 5.1));
            let x0 = mix(0.32, a - 0.32, (fk + 0.5) / f32(n_paddles));
            let y0 = 0.25 + 0.50 * h_k.x;
            let seed_v = vec2<f32>(fk * 43.1 + f32(gen) * 19.7 + 1.3, g.seed * 97.0 + fk * 7.9);
            let pad_pos = iso_waypoint_pos(
                vec2<f32>(x0, y0),
                h_k.y * TAU,
                seed_v,
                phase,
                0.46,
                0.24,
                a - 0.24,
                0.22,
                0.78,
                0.65,
                1.25,
                28u,
            );
            let to_pad = pos - pad_pos;
            let d_pad = length(to_pad);
            if (d_pad < 0.56) {
                let w = smoothstep(0.56, 0.06, d_pad);
                let radial = safe_norm2(to_pad, vec2<f32>(1.0, 0.0));
                let spin_dir = select(-1.0, 1.0, (k & 1u) == 0u);
                let tang = vec2<f32>(-radial.y, radial.x) * spin_dir;
                let pull = smoothstep(0.56, 0.22, d_pad) * smoothstep(0.06, 0.16, d_pad);
                let core_push = smoothstep(0.11, 0.015, d_pad);
                acc = acc + radial * (2.2 * core_push - 2.35 * pull) + tang * (2.25 * w);
            }
        }
        return acc;
    }

    if (arch == 2u) {
        // Sweeping Alternating Geysers: vertical overturning gravity swaps floor/ceiling every 8.2s with distributed sweeping plumes.
        let turn_u = phase / 8.2;
        let turn_i = floor(turn_u);
        let turn_f = turn_u - turn_i;
        let flip_ang = (turn_i + smoothstep(0.30, 0.70, turn_f)) * PI;
        let flip_wave = abs(sin(flip_ang)) * sin(pos.x * 2.2 + phase * 1.4 + ph0) * 0.45;
        var acc = vec2<f32>(flip_wave, -cos(flip_ang) * 1.25);

        let down_w = smoothstep(-0.20, 0.20, -acc.y);
        let up_w = smoothstep(-0.20, 0.20, acc.y);
        let h_down = clamp((pos.y - TANK_PAD) / 0.62, 0.0, 1.0);
        let h_up = clamp(((1.0 - TANK_PAD) - pos.y) / 0.62, 0.0, 1.0);
        let y_gate_down = (1.0 - h_down * h_down) * down_w;
        let y_gate_up = (1.0 - h_up * h_up) * up_w;

        let n_jets = select(4u, 2u, a < 2.4);
        var near_jx = pos.x;
        var near_d = 1e6;
        for (var k = 0u; k < n_jets; k = k + 1u) {
            let fk = f32(k);
            let x0 = mix(0.18, a - 0.18, (fk + 0.5) / f32(n_jets));
            let dir = select(-1.0, 1.0, (k & 1u) == 0u);
            let jx = reflect_range(x0 + dir * 0.36 * phase, 0.12, a - 0.12);
            let dx = pos.x - jx;
            let adx = abs(dx);
            if (adx < near_d) {
                near_d = adx;
                near_jx = jx;
            }
            let gauss = exp(-(dx * dx) / (0.17 * 0.17));
            let fan_x = dx * 2.6 + 0.42 * cos(phase * 2.0 + fk * 1.7 + ph0);
            if (y_gate_down > 0.01) {
                let w = gauss * y_gate_down;
                acc = acc + vec2<f32>(fan_x * w, 6.8 * w);
            }
            if (y_gate_up > 0.01) {
                let w = gauss * y_gate_up;
                acc = acc + vec2<f32>(fan_x * w, -6.8 * w);
            }
        }

        if (down_w > 0.05 && pos.y < TANK_PAD + 0.16) {
            acc.x = acc.x + clamp((near_jx - pos.x) * 2.4, -1.2, 1.2) * down_w;
        }
        if (up_w > 0.05 && pos.y > 1.0 - TANK_PAD - 0.16) {
            acc.x = acc.x + clamp((near_jx - pos.x) * 2.4, -1.2, 1.2) * up_w;
        }

        acc.x = acc.x + (edge_l - edge_r) * 0.70;
        acc.y = acc.y + (1.0 - density) * 0.55 * (down_w - up_w);
        return acc;
    }

    // Elastic Convective Arena: divergence-free isotropic convective cells + speed thermostat (no corner bias).
    let k1 = 3.1;
    let k2 = 2.1;
    let ax = pos.x * k1 - phase * 0.62 + ph0;
    let by = pos.y * k1 + phase * 0.54 + ph0 * 1.3;
    let cx = pos.x * k2 + pos.y * k2 - phase * 0.78 + ph0 * 0.7;
    let dpsi_dx = 0.25 * k1 * cos(ax) * sin(by) - 0.15 * k2 * sin(cx);
    let dpsi_dy = 0.25 * k1 * sin(ax) * cos(by) - 0.15 * k2 * sin(cx);
    var acc = vec2<f32>(-dpsi_dy, dpsi_dx) * 0.85;

    let spd = length(vel);
    let target_spd = 0.65;
    if (spd > 1e-4) {
        acc = acc + (vel / spd) * clamp((target_spd - spd) * 1.65, -0.50, 0.85);
    }
    return acc;
}

fn clamp_to_tank(
    pos_in: vec2<f32>,
    vel_in: vec2<f32>,
    r: f32,
    a: f32,
    spec: TankSpec,
) -> vec4<f32> {
    var p = pos_in;
    var v = vel_in;
    let x_lo = TANK_PAD + r;
    let x_hi = a - TANK_PAD - r;
    let y_lo = TANK_PAD + r;
    let y_hi = 1.0 - TANK_PAD - r;

    if (p.x < x_lo) {
        p.x = x_lo;
        if (v.x < 0.0) {
            v.x = -v.x * spec.wall_restitution;
            v.y = v.y * 0.97;
        }
    } else if (p.x > x_hi) {
        p.x = x_hi;
        if (v.x > 0.0) {
            v.x = -v.x * spec.wall_restitution;
            v.y = v.y * 0.97;
        }
    }
    if (p.y < y_lo) {
        p.y = y_lo;
        if (v.y < 0.0) {
            v.y = -v.y * spec.wall_restitution;
            v.x = v.x * 0.97;
        }
    } else if (p.y > y_hi) {
        p.y = y_hi;
        if (v.y > 0.0) {
            v.y = -v.y * spec.wall_restitution;
            v.x = v.x * 0.97;
        }
    }
    return vec4<f32>(p, v);
}

fn spawn_bead(
    arch: u32,
    pal_id: u32,
    ball_id: u32,
    n_active: u32,
    gen: u32,
    a: f32,
) -> Particle {
    let fi = f32(ball_id);
    let fg = f32(gen);
    let h0 = hash22(vec2<f32>(fi * 1.73 + fg * 17.3, fg * 31.7 + g.seed * 67.0));
    let h1 = hash22(vec2<f32>(fi * 2.91 + fg * 19.3, fg * 41.1 + g.seed * 53.0));

    let class_id = ball_id % 4u;
    var r = 0.024;
    var density = 1.0;
    if (class_id == 0u) {
        r = 0.030 + 0.004 * h0.x;
        density = 1.25;
    } else if (class_id == 1u) {
        r = 0.025 + 0.004 * h0.x;
        density = 1.05;
    } else if (class_id == 2u) {
        r = 0.021 + 0.003 * h0.x;
        density = 0.90;
    } else {
        r = 0.017 + 0.003 * h0.x;
        density = 0.75;
    }

    // Stratified 1:1 grid across the full tank avoids initial bead overlaps.
    let rows = max(round(sqrt(f32(n_active) / max(a, 0.5))), 4.0);
    let cols = ceil(f32(n_active) / rows);
    let gx = (fi % cols + 0.5 + (h0.x - 0.5) * 0.48) / cols;
    let gy = (floor(fi / cols) + 0.5 + (h0.y - 0.5) * 0.48) / rows;
    let margin = TANK_PAD + r * 1.4;
    let pos = vec2<f32>(
        mix(margin, a - margin, clamp(gx, 0.0, 1.0)),
        mix(margin, 1.0 - margin, clamp(gy, 0.0, 1.0)),
    );

    let ang = h1.x * TAU;
    let rel = pos - vec2<f32>(a * 0.5, 0.5);
    var vel = vec2<f32>(cos(ang), sin(ang)) * (0.35 + 0.24 * h1.y);
    if (arch == 0u) {
        vel = vel + vec2<f32>(0.42 * cos(pos.x * 1.8), 0.36 * sin(pos.x * 1.8));
    } else if (arch == 1u) {
        let dir = safe_norm2(vec2<f32>(-rel.y, rel.x * 0.55), vec2<f32>(1.0, 0.0));
        vel = vel * 0.65 + dir * (0.38 + 0.20 * h1.y);
    } else if (arch == 2u) {
        vel = vec2<f32>(cos(ang) * 0.38, 0.42 + 0.26 * h1.y);
    } else {
        vel = vec2<f32>(cos(ang), sin(ang)) * (0.55 + 0.20 * h1.y);
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
    a: f32,
) {
    if (env <= 0.003) {
        return;
    }
    let alpha_env = env * bezel_fade(world_p, a);
    if (alpha_env <= 0.003) {
        return;
    }

    let dims = splat_dims();
    let uv = state_uv(world_p);
    let center_px = uv * vec2<f32>(dims) - 0.5;
    let px_r = r * f32(dims.y);
    let ir = clamp(i32(ceil(px_r + 1.2)), 1, 24);
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
            if (cx < 0 || cx >= dims.x) {
                continue;
            }
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

            splat_pixel(vec2<i32>(cx, cy), vec4<f32>(shaded * cov, cov));
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
    let n_active = clamp(u32(round(81.0 * a)), 96u, MAX_BALLS);
    if (ball_id >= n_active) {
        return;
    }

    let seed_off = (0.14 + 0.56 * hash11(g.seed * 41.0 + 3.7)) * EPOCH_SECS;
    let cycle_t = t + seed_off;
    let gen = u32(max(floor(cycle_t / EPOCH_SECS), 0.0));
    let phase = cycle_t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.06, u_epoch) * (1.0 - smoothstep(0.94, 1.0, u_epoch));

    let arch = (gen + u32(g.seed * 13.0)) % 4u;
    let pal_id = (gen * 3u + u32(g.seed * 17.0)) % 4u;
    let spec = tank_spec(arch);

    let st = particles[read_base + ball_id];
    let packed_now = f32((gen % 16777215u) + 1u);
    let uninit = g.frame < 0.5
        || st.c.w <= 0.5
        || abs(st.c.w - packed_now) > 0.5
        || !all(st.p.xyz == st.p.xyz)
        || !all(st.v.xyz == st.v.xyz);

    if (uninit) {
        let sp = spawn_bead(arch, pal_id, ball_id, n_active, gen, a);
        particles[write_base + ball_id] = sp;
        splat_bead(sp.p.xy, sp.p.z, sp.c.rgb, sp.p.w, sp.v.w, env, a);
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

    let acc = tank_accel(arch, gen, phase, p, v, density, a);
    v = clamp_len(v + acc * dt, MAX_SPEED);
    let p_pred = p + v * dt;

    var corr = vec2<f32>(0.0);
    var dv = vec2<f32>(0.0);
    var v_xsph = vec2<f32>(0.0);
    var hit_count = 0.0;
    var spin_kick = 0.0;

    let det_seed = f32(ball_id) * 0.73 + f32(frame_u % 97u) * 0.19;

    for (var j = 0u; j < n_active; j = j + 1u) {
        if (j == ball_id) {
            continue;
        }
        let nb = particles[read_base + j];
        if (nb.c.w <= 0.5 || abs(nb.c.w - packed_now) > 0.5 || !all(nb.p.xyz == nb.p.xyz)) {
            continue;
        }
        let rj = nb.p.z;
        let min_d = ri + rj;
        let smooth_r = min_d * 1.65;
        let pj_pred = nb.p.xy + nb.v.xy * dt;
        let dvec = p_pred - pj_pred;
        if (abs(dvec.x) >= smooth_r || abs(dvec.y) >= smooth_r) {
            continue;
        }
        let dist2 = dot(dvec, dvec);
        if (dist2 >= smooth_r * smooth_r) {
            continue;
        }
        let dist = sqrt(max(dist2, 0.0));
        let mj = rj * rj * max(nb.v.z, 0.4);
        let w_i = mj / max(mi + mj, 1e-6);

        if (dist < min_d) {
            var n = vec2<f32>(cos(det_seed + f32(j)), sin(det_seed + f32(j)));
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
    let clamped = clamp_to_tank(p_new, v_new, ri, a, spec);
    p_new = clamped.xy;
    v_new = clamped.zw;
    let wall_dv = length(v_new - pre_clamp_v);
    if (wall_dv > 0.05) {
        impact_e = max(impact_e, clamp(wall_dv * 0.85, 0.0, 1.0));
    }

    v_new = clamp_len(v_new, MAX_SPEED);
    spin = spin + (spin_kick + length(v_new) * 1.4 * select(-1.0, 1.0, (ball_id & 1u) == 0u)) * dt;

    if (!all(p_new == p_new) || !all(v_new == v_new)) {
        let sp = spawn_bead(arch, pal_id, ball_id, n_active, gen, a);
        particles[write_base + ball_id] = sp;
        return;
    }

    var next_st: Particle;
    next_st.p = vec4<f32>(p_new, ri, clamp(impact_e, 0.0, 1.0));
    next_st.v = vec4<f32>(v_new, density, spin);
    next_st.c = vec4<f32>(col, packed_now);
    particles[write_base + ball_id] = next_st;

    splat_bead(p_new, ri, col, next_st.p.w, spin, env, a);
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    let dims = splat_dims();
    var prev = state_sample(uv);
    if (dims.y >= 180) {
        let tex = state_texel();
        let blur = (
            state_sample(uv + vec2<f32>(tex.x, 0.0))
            + state_sample(uv - vec2<f32>(tex.x, 0.0))
            + state_sample(uv + vec2<f32>(0.0, tex.y))
            + state_sample(uv - vec2<f32>(0.0, tex.y))
        ) * 0.25;
        let diff = clamp(g.dt * 18.0, 0.0, 0.44);
        prev = mix(prev, blur, diff);
    }

    // Step vacated bead interiors down sharply so moving beads leave a soft liquid shimmer instead of stepped rings.
    let wake_drop = mix(0.62, 0.08, clamp(prev.a, 0.0, 1.0));
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
