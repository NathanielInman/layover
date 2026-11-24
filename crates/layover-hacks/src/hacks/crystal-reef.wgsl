// Crystal Reef: branching coral dendrites and faceted frost crystals accreting
// and dissolving across the dark.
// After xscreensaver's Coral (Frederick Roeber, 1997) and Crystal (Jouk Jansen, 1998).
//
// 4-channel Rgba16Float state encoding (toroidal repeat integer-grid cells):
//   Active tip (x < -0.5):
//     x = -(f32(code) + hue), code in 1..=6, hue in [0.02, 0.98]
//     y = theta in [0, TAU)
//     z = ox, w = oy in [-0.5, 0.5] (sub-texel tip position)
//   Passive calcified/crystallized segment (x > WALL_MIN):
//     x = life (1.0 -> decays by g.fade)
//     y = theta in [0, TAU)
//     z = perp_off in [-0.71, 0.71]
//     w = f32(tier) + hue (tier in 0..=2, hue in [0.02, 0.98])
//   Empty fluid/vapor cell (-0.5 <= x <= WALL_MIN):
//     x = 0.0
//     y = halo_theta
//     z = halo_strength (0.0..1.0, decayed smoothly by g.fade * exp(-dt * 0.65))
//     w = halo_hue (0.02..0.98)

const STEP_LEN: f32 = 0.85;
const REF_HEIGHT: f32 = 160.0;
const REF_TICK_HZ: f32 = 14.0;
const WALL_MIN: f32 = 0.018;
const COLLIDE_MIN: f32 = 0.22;
const WAVES_PER_STAGE: i32 = 12;

struct ClockInfo {
    tick_hz: f32,
    ticks_per_beat: i32,
    wave_ticks: i32,
    tick_now: i32,
    tick_prev: i32,
    do_tick: bool,
    beat_crossed: bool,
    wave_idx: i32,
    beat_in_wave: i32,
    tick_in_wave: i32,
    wave_ending: bool,
    stage: u32,
    stage_prev: u32,
    stage_blend: f32,
};

fn tex_dims() -> vec2<i32> {
    return vec2<i32>(textureDimensions(state_tex));
}

fn load_wrap(coord: vec2<i32>, dims: vec2<i32>) -> vec4<f32> {
    let w = ((coord % dims) + dims) % dims;
    return textureLoad(state_tex, w, 0);
}

fn wrap_coord(coord: vec2<i32>, dims: vec2<i32>) -> vec2<i32> {
    return ((coord % dims) + dims) % dims;
}

fn wrap_tau(a: f32) -> f32 {
    return fract(a / TAU) * TAU;
}

fn hue_dist(a: f32, b: f32) -> f32 {
    let d = abs(fract(a) - fract(b));
    return min(d, 1.0 - d);
}

fn is_clear_texel(v: vec4<f32>) -> bool {
    return v.x <= WALL_MIN && v.x >= -0.5;
}

// Keep hues in [0.02, 0.98] away from exact 0.25/0.5/0.75 band cuts so f16
// quantization never flips 4-fold vs 8-fold parity across code changes.
fn safe_hue(raw: f32) -> f32 {
    let h = clamp(fract(raw), 0.02, 0.98);
    let band = floor(h * 4.0);
    let inside = clamp(fract(h * 4.0), 0.08, 0.92);
    return clamp((band + inside) * 0.25, 0.02, 0.98);
}

fn is_eight_fold_hue(hue: f32) -> bool {
    return fract(hue * 4.0) > 0.50;
}

fn tier_of_code(code: i32) -> i32 {
    if (code <= 2) {
        return 0;
    }
    if (code <= 4) {
        return 1;
    }
    return 2;
}

// Exact 45-degree 8-neighbor direction table (no cardinal bias from round()).
fn dir_to_step8(a: f32) -> vec2<i32> {
    let oct = i32(floor(fract(a / TAU + 0.0625) * 8.0)) % 8;
    if (oct == 0) {
        return vec2<i32>(1, 0);
    }
    if (oct == 1) {
        return vec2<i32>(1, 1);
    }
    if (oct == 2) {
        return vec2<i32>(0, 1);
    }
    if (oct == 3) {
        return vec2<i32>(-1, 1);
    }
    if (oct == 4) {
        return vec2<i32>(-1, 0);
    }
    if (oct == 5) {
        return vec2<i32>(-1, -1);
    }
    if (oct == 6) {
        return vec2<i32>(0, -1);
    }
    return vec2<i32>(1, -1);
}

fn clock_info(t: f32, dt: f32, dims_y: f32) -> ClockInfo {
    let tick_hz = clamp(dims_y * (REF_TICK_HZ / REF_HEIGHT), 6.0, REF_TICK_HZ);
    let ticks_per_beat = max(i32(round(tick_hz * 0.7857)), 4);
    let wave_ticks = ticks_per_beat * 4;
    let tick_now = i32(floor(max(t, 0.0) * tick_hz + 0.02));
    let tick_prev = i32(floor(max(t - dt, 0.0) * tick_hz + 0.02));
    let do_tick = tick_now > tick_prev;
    let beat_num_now = tick_now / ticks_per_beat;
    let beat_num_prev = tick_prev / ticks_per_beat;
    let beat_crossed = do_tick && (beat_num_now > beat_num_prev);
    let wave_idx = beat_num_now / 4;
    let beat_in_wave = beat_num_now % 4;
    let tick_in_wave = tick_now % wave_ticks;
    let wave_ending = do_tick && (tick_in_wave >= wave_ticks - 1);
    let stage_num = wave_idx / WAVES_PER_STAGE;
    let stage = u32(stage_num) % 3u;
    let stage_prev = u32(max(stage_num - 1, 0)) % 3u;
    let stage_start_t = f32(stage_num * WAVES_PER_STAGE * wave_ticks) / tick_hz;
    let t_in_stage = max(t - stage_start_t, 0.0);
    let stage_blend = select(smoothstep(0.0, 1.5, t_in_stage), 1.0, stage_num == 0);
    return ClockInfo(
        tick_hz,
        ticks_per_beat,
        wave_ticks,
        tick_now,
        tick_prev,
        do_tick,
        beat_crossed,
        wave_idx,
        beat_in_wave,
        tick_in_wave,
        wave_ending,
        stage,
        stage_prev,
        stage_blend,
    );
}

// Balanced 6-stop reef and mineral jewel wheel keeping R/G/B channel shares even.
fn reef_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.22, 0.50, 0.96);
    let aquamarine = vec3<f32>(0.16, 0.88, 0.80);
    let emerald = vec3<f32>(0.34, 0.90, 0.44);
    let coral_gold = vec3<f32>(0.98, 0.66, 0.16);
    let rose_quartz = vec3<f32>(0.98, 0.26, 0.48);
    let amethyst = vec3<f32>(0.74, 0.30, 0.94);
    let s = p * 6.0;
    if (s < 1.0) {
        return mix(sapphire, aquamarine, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(aquamarine, emerald, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(emerald, coral_gold, smoothstep(0.0, 1.0, s - 2.0));
    }
    if (s < 4.0) {
        return mix(coral_gold, rose_quartz, smoothstep(0.0, 1.0, s - 3.0));
    }
    if (s < 5.0) {
        return mix(rose_quartz, amethyst, smoothstep(0.0, 1.0, s - 4.0));
    }
    return mix(amethyst, sapphire, smoothstep(0.0, 1.0, s - 5.0));
}

fn coral_turn(ic: vec2<i32>, dims: vec2<i32>, t: f32, hue: f32) -> f32 {
    let uv = vec2<f32>(ic) / max(vec2<f32>(dims), vec2<f32>(1.0));
    let swirl = sin(uv.x * TAU * 3.0 + uv.y * TAU * 2.0 + t * 0.25 + hue * TAU * 3.0);
    let dir_s = select(-1.0, 1.0, fract(hue * 17.3 + swirl * 0.25) > 0.5);
    let base_rate = 0.022 + 0.018 * abs(swirl);
    return dir_s * base_rate * (REF_HEIGHT / max(f32(dims.y), 1.0));
}

fn coral_child_code(code: i32) -> i32 {
    if (code <= 1) {
        return 2;
    }
    if (code == 2) {
        return 3;
    }
    if (code <= 4) {
        return 5;
    }
    return 6;
}

fn crystal_main_stepdown(code: i32) -> i32 {
    if (code == 1) {
        return 2;
    }
    if (code == 2) {
        return 3;
    }
    if (code == 3) {
        return 6;
    }
    if (code == 4) {
        return 5;
    }
    return 6;
}

fn crystal_child_code(code: i32) -> i32 {
    if (code == 1) {
        return 4;
    }
    if (code == 2) {
        return 5;
    }
    return 6;
}

fn seed_count_for_beat(beat_in_wave: i32, asp: f32) -> i32 {
    if (beat_in_wave == 0) {
        return i32(clamp(round(asp * 1.75), 3.0, 6.0));
    }
    if (beat_in_wave == 1) {
        return i32(clamp(round(asp * 1.40), 2.0, 5.0));
    }
    if (beat_in_wave == 2) {
        return i32(clamp(round(asp * 1.25), 2.0, 4.0));
    }
    return 0;
}

fn seed_code_for_beat(beat_in_wave: i32) -> i32 {
    if (beat_in_wave == 0) {
        return 1;
    }
    if (beat_in_wave == 1) {
        return 2;
    }
    return 3;
}

// Compute seed center (sc), base rotation (theta_0), safe hue, and arm count.
fn seed_spec(
    idx: i32,
    count: i32,
    wave_idx: i32,
    beat_in_wave: i32,
    stage: u32,
    dims: vec2<i32>,
) -> vec4<f32> {
    let fw = f32(wave_idx);
    let fb = f32(beat_in_wave);
    let fi = f32(idx);
    let tag = fw * 19.7 + fb * 53.3 + fi * 11.1 + g.seed * 71.0;
    let h0 = hash22(vec2<f32>(tag, tag * 0.73 + 5.1));
    let h1 = hash22(vec2<f32>(tag * 1.31 + 2.7, fi * 7.9 + fw * 3.7));

    // Stratified across aspect() + golden-ratio progression between waves.
    let x_slot = (fi + 0.14 + 0.72 * h0.x) / max(f32(count), 1.0);
    let x_shift = fract(fw * 0.381966 + fb * 0.3333);
    let fx = fract(x_slot + x_shift);
    let fy = fract(0.14 + fw * 0.618034 + fb * 0.309017 + fi * 0.27 + h0.y * 0.19);
    let sc = vec2<i32>(
        clamp(i32(floor(fx * f32(dims.x))), 0, dims.x - 1),
        clamp(i32(floor(fy * f32(dims.y))), 0, dims.y - 1),
    );
    // Keep theta_0 slightly off exact 22.5-deg boundaries for crisp 8-neighbor assignment.
    let theta_0 = wrap_tau(h1.x * TAU + 0.041);
    let hue = safe_hue(fi / max(f32(count), 1.0) + fw * 0.23 + fb * 0.31 + h1.y * 0.17 + g.seed * 1.7);
    return vec4<f32>(f32(sc.x), f32(sc.y), theta_0, hue);
}

fn seed_arm_count(stage: u32, beat_in_wave: i32, hue: f32, tag: f32) -> i32 {
    if (stage == 0u) {
        if (beat_in_wave == 0) {
            return select(3, 4, hash11(tag) > 0.45);
        }
        return 3;
    }
    if (stage == 1u) {
        return 6;
    }
    return select(4, 8, is_eight_fold_hue(hue));
}

fn seed_arm_angle(
    stage: u32,
    k: i32,
    n_arms: i32,
    theta_0: f32,
    tag: f32,
) -> f32 {
    let fk = f32(k);
    let fn_arms = max(f32(n_arms), 1.0);
    if (stage == 0u) {
        let jitter = (hash11(tag + fk * 7.3) - 0.5) * 0.42;
        return wrap_tau(theta_0 + fk * (TAU / fn_arms) + jitter);
    }
    return wrap_tau(theta_0 + fk * (TAU / fn_arms));
}

fn try_seed_at_ic(
    ic: vec2<i32>,
    dims: vec2<i32>,
    wave_idx: i32,
    beat_in_wave: i32,
    stage: u32,
    can_write_arm: bool,
    force_center_clear: bool,
) -> vec4<f32> {
    let asp = aspect();
    let count = seed_count_for_beat(beat_in_wave, asp);
    let s_code = seed_code_for_beat(beat_in_wave);
    let s_tier = tier_of_code(s_code);

    for (var idx: i32 = 0; idx < 6; idx = idx + 1) {
        if (idx >= count) {
            break;
        }
        let sp = seed_spec(idx, count, wave_idx, beat_in_wave, stage, dims);
        let sc = vec2<i32>(i32(sp.x), i32(sp.y));
        var d = ic - sc;
        if (d.x > dims.x / 2) {
            d.x = d.x - dims.x;
        } else if (d.x < -dims.x / 2) {
            d.x = d.x + dims.x;
        }
        if (d.y > dims.y / 2) {
            d.y = d.y - dims.y;
        } else if (d.y < -dims.y / 2) {
            d.y = d.y + dims.y;
        }
        if (abs(d.x) > 1 || abs(d.y) > 1) {
            continue;
        }

        if (!force_center_clear) {
            let sc_val = load_wrap(sc, dims);
            if (sc_val.x > 0.30 || sc_val.x < -0.5) {
                continue;
            }
        }

        let theta_0 = sp.z;
        let hue = sp.w;
        let tag = f32(wave_idx) * 17.3 + f32(idx) * 5.9 + f32(beat_in_wave) * 3.1;

        if (d.x == 0 && d.y == 0) {
            return vec4<f32>(1.0, theta_0, 0.0, f32(s_tier) + hue);
        }

        if (!can_write_arm) {
            continue;
        }
        let n_arms = seed_arm_count(stage, beat_in_wave, hue, tag);
        for (var k: i32 = 0; k < 8; k = k + 1) {
            if (k >= n_arms) {
                break;
            }
            let ak = seed_arm_angle(stage, k, n_arms, theta_0, tag);
            let step_k = dir_to_step8(ak);
            if (step_k.x == d.x && step_k.y == d.y) {
                let dir_k = vec2<f32>(cos(ak), sin(ak));
                let o_init = clamp(
                    dir_k * 1.10 - vec2<f32>(step_k),
                    vec2<f32>(-0.45),
                    vec2<f32>(0.45),
                );
                return vec4<f32>(-(f32(s_code) + hue), ak, o_init.x, o_init.y);
            }
        }
    }
    return vec4<f32>(0.0);
}

fn empty_halo_step(nb: array<vec4<f32>, 9>, dt: f32) -> vec4<f32> {
    let c = nb[4];
    var halo_str = max(c.z, 0.0) * 0.55;
    var hue_vec = vec2<f32>(cos(c.w * TAU), sin(c.w * TAU)) * max(c.z, 0.004);
    var dir_vec = vec2<f32>(cos(c.y * 2.0), sin(c.y * 2.0)) * max(c.z, 0.004);
    var weight_sum = 0.55;

    for (var j: i32 = 0; j < 9; j = j + 1) {
        if (j == 4) {
            continue;
        }
        let n = nb[j];
        let is_card = (j == 1 || j == 3 || j == 5 || j == 7);
        let w_k = select(0.06, 0.14, is_card);
        if (n.x > WALL_MIN) {
            let emit = clamp(n.x * 0.42, 0.0, 0.42);
            let n_hue = fract(n.w);
            let a_h = n_hue * TAU;
            let a_t = n.y * 2.0;
            halo_str = halo_str + emit * w_k;
            hue_vec = hue_vec + vec2<f32>(cos(a_h), sin(a_h)) * (emit * w_k);
            dir_vec = dir_vec + vec2<f32>(cos(a_t), sin(a_t)) * (emit * w_k);
            weight_sum = weight_sum + w_k;
        } else if (n.x >= -0.5 && n.z > 0.005) {
            let a_h = n.w * TAU;
            let a_t = n.y * 2.0;
            halo_str = halo_str + n.z * w_k;
            hue_vec = hue_vec + vec2<f32>(cos(a_h), sin(a_h)) * (n.z * w_k);
            dir_vec = dir_vec + vec2<f32>(cos(a_t), sin(a_t)) * (n.z * w_k);
            weight_sum = weight_sum + w_k;
        }
    }

    let next_str = clamp((halo_str / max(weight_sum, 1e-4)) * g.fade * exp(-dt * 0.65), 0.0, 0.55);
    if (next_str < 0.003) {
        return vec4<f32>(0.0);
    }
    let next_hue = select(
        c.w,
        safe_hue(atan2(hue_vec.y, hue_vec.x) / TAU),
        length(hue_vec) > 1e-5,
    );
    let next_theta = select(
        c.y,
        wrap_tau(atan2(dir_vec.y, dir_vec.x) * 0.5),
        length(dir_vec) > 1e-5,
    );
    return vec4<f32>(0.0, next_theta, next_str, next_hue);
}

fn step_state(uv: vec2<f32>, _p: vec2<f32>, t: f32) -> vec4<f32> {
    let dims = tex_dims();
    let ic = clamp(vec2<i32>(floor(uv * vec2<f32>(dims))), vec2<i32>(0), dims - vec2<i32>(1));
    let clk = clock_info(t, g.dt, f32(dims.y));

    if (g.frame < 0.5) {
        return try_seed_at_ic(ic, dims, 0, 0, 0u, true, true);
    }

    var nb: array<vec4<f32>, 9>;
    var k: i32 = 0;
    for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
        for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
            nb[k] = load_wrap(ic + vec2<i32>(dx, dy), dims);
            k = k + 1;
        }
    }
    let c = nb[4];

    // Inter-tick substep: keep tips frozen in place, fade passive segments and halos.
    if (!clk.do_tick) {
        if (c.x < -0.5) {
            return c;
        }
        if (c.x > WALL_MIN) {
            let life = c.x * g.fade;
            if (life > WALL_MIN) {
                return vec4<f32>(life, c.y, c.z, c.w);
            }
            return vec4<f32>(0.0, c.y, 0.14, safe_hue(c.w));
        }
        return empty_halo_step(nb, g.dt);
    }

    // End-of-wave cleanup: freeze any remaining active tip cleanly into passive solid.
    if (clk.wave_ending && c.x < -0.5) {
        let code = clamp(i32(floor(-c.x)), 1, 6);
        let hue = safe_hue(-c.x);
        let tier = tier_of_code(code);
        let dir = vec2<f32>(cos(c.y), sin(c.y));
        let nrm = vec2<f32>(-dir.y, dir.x);
        let perp_off = clamp(dot(vec2<f32>(c.z, c.w), nrm), -0.71, 0.71);
        return vec4<f32>(1.0, c.y, perp_off, f32(tier) + hue);
    }

    // Case 1: Active tip at ic updates (pause/branch on beat_crossed or march).
    if (c.x < -0.5) {
        let code = clamp(i32(floor(-c.x)), 1, 6);
        let hue = safe_hue(-c.x);
        let tier = tier_of_code(code);
        let dir = vec2<f32>(cos(c.y), sin(c.y));
        let nrm = vec2<f32>(-dir.y, dir.x);
        let perp_off = clamp(dot(vec2<f32>(c.z, c.w), nrm), -0.71, 0.71);

        if (clk.beat_crossed) {
            if (code >= 6 || clk.stage == 0u) {
                return vec4<f32>(1.0, c.y, perp_off, f32(tier) + hue);
            }
            let next_code = crystal_main_stepdown(code);
            return vec4<f32>(-(f32(next_code) + hue), c.y, c.z, c.w);
        }

        let r = vec2<f32>(c.z, c.w) + STEP_LEN * dir;
        let delta = vec2<i32>(floor(r + 0.5));
        var next_theta = c.y;
        if (clk.stage == 0u) {
            next_theta = wrap_tau(c.y + coral_turn(ic, dims, t, hue));
        }
        if (delta.x == 0 && delta.y == 0) {
            return vec4<f32>(c.x, next_theta, r.x, r.y);
        }
        return vec4<f32>(1.0, c.y, perp_off, f32(tier) + hue);
    }

    // Case 2a: Normal tick - check if an 8-neighbor active tip marches into ic.
    if (!clk.beat_crossed && !clk.wave_ending) {
        for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
            for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
                if (dx == 0 && dy == 0) {
                    continue;
                }
                let n = nb[(dy + 1) * 3 + (dx + 1)];
                if (n.x >= -0.5) {
                    continue;
                }
                let dir_n = vec2<f32>(cos(n.y), sin(n.y));
                let r_n = vec2<f32>(n.z, n.w) + STEP_LEN * dir_n;
                let delta_n = vec2<i32>(floor(r_n + 0.5));
                if (delta_n.x != -dx || delta_n.y != -dy) {
                    continue;
                }
                let n_code = clamp(i32(floor(-n.x)), 1, 6);
                let n_hue = safe_hue(-n.x);
                let n_tier = tier_of_code(n_code);
                let hit_self = c.x > COLLIDE_MIN;
                var hit_diag = false;
                if (dx != 0 && dy != 0) {
                    let nb_x = nb[1 * 3 + (1 + dx)];
                    let nb_y = nb[(1 + dy) * 3 + 1];
                    hit_diag = (nb_x.x > COLLIDE_MIN) && (nb_y.x > COLLIDE_MIN);
                }
                let new_o = r_n - vec2<f32>(delta_n);
                if (hit_self || hit_diag) {
                    if (c.x > WALL_MIN) {
                        if (hue_dist(fract(c.w), n_hue) < 0.04) {
                            let weld = max(c.x * g.fade, min(1.0, c.x + 0.15));
                            return vec4<f32>(weld, c.y, c.z, c.w);
                        }
                        return vec4<f32>(c.x * g.fade, c.y, c.z, c.w);
                    }
                    let nrm_n = vec2<f32>(-dir_n.y, dir_n.x);
                    let perp_n = clamp(dot(new_o, nrm_n), -0.71, 0.71);
                    return vec4<f32>(0.90, n.y, perp_n, f32(n_tier) + n_hue);
                }
                var next_theta = n.y;
                if (clk.stage == 0u) {
                    next_theta = wrap_tau(n.y + coral_turn(ic, dims, t, n_hue));
                }
                return vec4<f32>(n.x, next_theta, new_o.x, new_o.y);
            }
        }
    }

    // Case 2b: Beat-crossing branching from an adjacent active tip into empty ic.
    if (clk.beat_crossed && !clk.wave_ending && is_clear_texel(c)) {
        for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
            for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
                if (dx == 0 && dy == 0) {
                    continue;
                }
                let n = nb[(dy + 1) * 3 + (dx + 1)];
                if (n.x >= -0.5) {
                    continue;
                }
                let n_code = clamp(i32(floor(-n.x)), 1, 6);
                let n_hue = safe_hue(-n.x);
                if (n_code >= 6 || (clk.stage == 2u && n_code >= 5)) {
                    continue;
                }

                let n_ic = wrap_coord(ic + vec2<i32>(dx, dy), dims);
                var b_ang = PI / 3.0;
                var child_code = crystal_child_code(n_code);
                if (clk.stage == 0u) {
                    let h_fork = hash21(vec2<f32>(n_ic) + vec2<f32>(f32(clk.wave_idx) * 3.7, n_hue * 19.0));
                    b_ang = 0.48 + 0.14 * h_fork;
                    child_code = coral_child_code(n_code);
                } else if (clk.stage == 2u) {
                    let is_8 = is_eight_fold_hue(n_hue);
                    b_ang = select(PI * 0.5, PI * 0.25, is_8 && n_code <= 3);
                }

                let target_step = vec2<i32>(-dx, -dy);
                for (var side_i: i32 = 0; side_i < 2; side_i = side_i + 1) {
                    let sgn = select(-1.0, 1.0, side_i == 0);
                    let b_theta = wrap_tau(n.y + sgn * b_ang);
                    let b_step = dir_to_step8(b_theta);
                    if (b_step.x == target_step.x && b_step.y == target_step.y) {
                        let b_dir = vec2<f32>(cos(b_theta), sin(b_theta));
                        let o_init = clamp(
                            b_dir * 1.10 - vec2<f32>(b_step),
                            vec2<f32>(-0.45),
                            vec2<f32>(0.45),
                        );
                        return vec4<f32>(-(f32(child_code) + n_hue), b_theta, o_init.x, o_init.y);
                    }
                }
            }
        }
    }

    // Case 3: Passive calcified/crystallized segment fades on real time.
    if (c.x > WALL_MIN) {
        let life = c.x * g.fade;
        if (life > WALL_MIN) {
            return vec4<f32>(life, c.y, c.z, c.w);
        }
        return vec4<f32>(0.0, c.y, 0.14, safe_hue(c.w));
    }

    // Case 4: Multi-scale staggered wave seeding on beat crossings 0, 1, 2.
    if (clk.beat_crossed && clk.beat_in_wave <= 2 && is_clear_texel(c)) {
        let seeded = try_seed_at_ic(
            ic,
            dims,
            clk.wave_idx,
            clk.beat_in_wave,
            clk.stage,
            !clk.wave_ending,
            false,
        );
        if (seeded.x > WALL_MIN || seeded.x < -0.5) {
            return seeded;
        }
    }

    // Case 5: Empty cell diffused halo mist / frost webbing.
    return empty_halo_step(nb, g.dt);
}

fn segment_dist(rel: vec2<f32>, dir: vec2<f32>, a_min: f32, a_max: f32) -> vec2<f32> {
    let proj = dot(rel, dir);
    let along = clamp(proj, a_min, a_max);
    let d_line = length(rel - dir * along);
    let nrm = vec2<f32>(-dir.y, dir.x);
    let side = dot(rel, nrm);
    return vec2<f32>(d_line, side);
}

fn shade_segment(
    d_line: f32,
    side: f32,
    along_u: f32,
    hw: f32,
    aa: f32,
    life_pow: f32,
    base_hue: f32,
    theta: f32,
    t: f32,
    w0: f32,
    w1: f32,
    w2: f32,
) -> vec3<f32> {
    let pearl = vec3<f32>(0.96, 0.97, 1.00);
    var out = vec3<f32>(0.0);

    // Stage 0: Staghorn Coral - lush rounded calcareous tubes with polyp buds.
    if (w0 > 0.001) {
        let hw0 = hw * 1.48;
        let polyp = 1.0 + 0.13 * sin(along_u * 8.5 + theta * 2.0);
        let r0 = hw0 * polyp;
        let cov = smoothstep(0.0, 1.0, clamp((r0 + aa - d_line) / (2.0 * aa), 0.0, 1.0)) * min(1.0, r0 / aa);
        let u_tube = clamp(d_line / max(r0, 1e-4), 0.0, 1.0);
        let z_tube = sqrt(max(1.0 - u_tube * u_tube, 0.0));
        let ridge = pow(z_tube, 2.0) * 0.50;
        let halo = exp(-d_line * 0.95) * 0.36;
        let c_base = reef_palette(base_hue + t * 0.008);
        let c_tip = mix(c_base, pearl, 0.38);
        let tube_col = c_base * (0.64 + 0.50 * z_tube) + c_tip * ridge;
        let coral_col = (tube_col * cov * 1.24 + c_base * halo) * life_pow;
        out = out + coral_col * w0;
    }

    // Stage 1: Frost Dendrite - sharp triangular roof-beveled ice spears & chevrons.
    if (w1 > 0.001) {
        let hw1 = hw * 1.15;
        let cov = smoothstep(0.0, 1.0, clamp((hw1 + aa - d_line) / (2.0 * aa), 0.0, 1.0)) * min(1.0, hw1 / aa);
        let bevel = clamp(1.0 - d_line / max(hw1, 1e-4), 0.0, 1.0);
        let crest = pow(bevel, 2.4) * 0.85;
        let chev = 0.82 + 0.18 * cos(along_u * 10.5 - abs(side) * 7.0);
        let halo = exp(-d_line * 1.20) * 0.34;
        let c_ice = mix(reef_palette(base_hue + 0.02 + t * 0.008), vec3<f32>(0.78, 0.92, 1.00), 0.34);
        let frost_col = (c_ice * (cov * (0.54 + 0.72 * bevel) * chev + halo) + pearl * (crest * cov)) * life_pow;
        out = out + frost_col * w1;
    }

    // Stage 2: Prismatic Druse - terraced hopper facets with dichroic split dispersion.
    if (w2 > 0.001) {
        let hw2 = hw * 1.28;
        let step_notch = 1.0 - 0.15 * smoothstep(0.45, 0.95, abs(sin(along_u * 6.0)));
        let r2 = hw2 * step_notch;
        let cov = smoothstep(0.0, 1.0, clamp((r2 + aa - d_line) / (2.0 * aa), 0.0, 1.0)) * min(1.0, r2 / aa);
        let bevel = clamp(1.0 - d_line / max(r2, 1e-4), 0.0, 1.0);
        let side_sgn = clamp(side / max(r2 * 0.35, 1e-4), -1.0, 1.0);
        let facet_hue = base_hue + side_sgn * 0.08 + t * 0.008;
        let c_facet = reef_palette(facet_hue);
        let terrace = 0.72 + 0.28 * floor(bevel * 3.0) / 2.0;
        let edge_spark = pow(bevel, 2.2) * 0.70;
        let halo = exp(-d_line * 1.10) * 0.32;
        let druse_col = (c_facet * (cov * terrace * 1.16 + halo) + mix(c_facet, pearl, 0.58) * (edge_spark * cov)) * life_pow;
        out = out + druse_col * w2;
    }

    return out;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let dims = tex_dims();
    let dims_f = vec2<f32>(dims);
    let asp = aspect();
    let clk = clock_info(t, 0.0, dims_f.y);

    // Stage shading crossfade weights.
    var w0 = select(0.0, 1.0, clk.stage == 0u);
    var w1 = select(0.0, 1.0, clk.stage == 1u);
    var w2 = select(0.0, 1.0, clk.stage == 2u);
    if (clk.stage_blend < 0.999) {
        let p0 = select(0.0, 1.0, clk.stage_prev == 0u);
        let p1 = select(0.0, 1.0, clk.stage_prev == 1u);
        let p2 = select(0.0, 1.0, clk.stage_prev == 2u);
        w0 = mix(p0, w0, clk.stage_blend);
        w1 = mix(p1, w1, clk.stage_blend);
        w2 = mix(p2, w2, clk.stage_blend);
    }

    // Gentle monotonic toroidal drift so every lit feature crosses the panel.
    let drift = vec2<f32>(t * 0.032 / asp, t * 0.011 + 0.005 * sin(t * 0.15));
    let uv = fract(state_uv(p) + drift);
    let tc = uv * dims_f - vec2<f32>(0.5);

    let center_i = vec2<i32>(round(tc));
    let base = vec2<i32>(floor(tc));
    let f_bilin = tc - vec2<f32>(base);

    // Single 3x3 neighborhood load covers both 2x2 bilinear halo mist and 3x3 vector segments.
    var nb: array<vec4<f32>, 9>;
    var k: i32 = 0;
    for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
        for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
            nb[k] = load_wrap(center_i + vec2<i32>(ox, oy), dims);
            k = k + 1;
        }
    }

    // 1. Bilinear gossamer halo mist / hexagonal frost webbing (strictly below LIT).
    let bx0 = clamp(base.x - center_i.x + 1, 0, 1);
    let by0 = clamp(base.y - center_i.y + 1, 0, 1);
    var halo_sum = 0.0;
    var hue_vec = vec2<f32>(0.0);
    for (var qy: i32 = 0; qy <= 1; qy = qy + 1) {
        for (var qx: i32 = 0; qx <= 1; qx = qx + 1) {
            let s = nb[(by0 + qy) * 3 + (bx0 + qx)];
            let w = mix(1.0 - f_bilin.x, f_bilin.x, f32(qx)) * mix(1.0 - f_bilin.y, f_bilin.y, f32(qy));
            var h_val = 0.0;
            var h_hue = 0.0;
            if (s.x > WALL_MIN) {
                h_val = clamp(s.x * 0.35, 0.0, 0.35);
                h_hue = fract(s.w);
            } else if (s.x >= -0.5) {
                h_val = clamp(s.z, 0.0, 0.55);
                h_hue = s.w;
            }
            halo_sum = halo_sum + h_val * w;
            let ang = h_hue * TAU;
            hue_vec = hue_vec + vec2<f32>(cos(ang), sin(ang)) * (h_val * w);
        }
    }
    let halo_hue = select(0.0, fract(atan2(hue_vec.y, hue_vec.x) / TAU), length(hue_vec) > 1e-5);
    let mist_col = reef_palette(halo_hue + t * 0.008) * (smoothstep(0.03, 0.46, halo_sum) * 0.24);

    // 2. Analytical 3x3 vector segments + bright calcifying tips.
    let aa = max(0.20, 0.70 * dims_f.y / max(g.target_size.y, 1.0));
    let pearl = vec3<f32>(0.96, 0.97, 1.00);
    var seg_col = vec3<f32>(0.0);
    var tip_col = vec3<f32>(0.0);

    for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
        for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
            let ic = center_i + vec2<i32>(ox, oy);
            let c = nb[(oy + 1) * 3 + (ox + 1)];
            let cell_center = vec2<f32>(f32(ic.x), f32(ic.y));
            if (c.x > WALL_MIN) {
                let dir = vec2<f32>(cos(c.y), sin(c.y));
                let nrm = vec2<f32>(-dir.y, dir.x);
                let line_pt = cell_center + nrm * c.z;
                let rel = tc - line_pt;
                let sd = segment_dist(rel, dir, -0.92, 0.92);
                let along_u = dot(rel, dir);
                let tier = clamp(i32(floor(c.w)), 0, 2);
                var hw = 0.52;
                if (tier == 1) {
                    hw = 0.40;
                } else if (tier == 2) {
                    hw = 0.29;
                }
                let base_hue = fract(c.w);
                let life_pow = pow(clamp(c.x, 0.0, 1.0), 0.95);
                let col_s = shade_segment(
                    sd.x,
                    sd.y,
                    along_u,
                    hw,
                    aa,
                    life_pow,
                    base_hue,
                    c.y,
                    t,
                    w0,
                    w1,
                    w2,
                );
                seg_col = max(seg_col, col_s);
            } else if (c.x < -0.5) {
                let code = clamp(i32(floor(-c.x)), 1, 6);
                let tier = tier_of_code(code);
                var hw = 0.46;
                if (tier == 1) {
                    hw = 0.36;
                } else if (tier == 2) {
                    hw = 0.27;
                }
                let dir = vec2<f32>(cos(c.y), sin(c.y));
                let tip_pt = cell_center + vec2<f32>(c.z, c.w);
                let rel = tc - tip_pt;
                let sd = segment_dist(rel, dir, -0.95, 0.05);
                let stem_cov = smoothstep(0.0, 1.0, clamp((hw + aa - sd.x) / (2.0 * aa), 0.0, 1.0)) * min(1.0, hw / aa);
                let d_tip = length(rel);
                let tip_r = hw * 1.45;
                let tip_core = smoothstep(0.0, 1.0, clamp((tip_r + aa - d_tip) / (2.0 * aa), 0.0, 1.0)) * min(1.0, tip_r / aa);
                let tip_aura = exp(-d_tip * 1.55) * 0.72;
                let hue = safe_hue(-c.x);
                let t_base = reef_palette(hue + t * 0.008);
                let spear = mix(t_base, pearl, 0.36) * (stem_cov * 1.15)
                    + mix(t_base, pearl, 0.70) * (tip_core * 1.35 + tip_aura);
                tip_col = max(tip_col, spear);
            }
        }
    }

    let col = mist_col + seg_col + tip_col;
    return clamp(col / (vec3<f32>(1.0) + col * 0.14), vec3<f32>(0.0), vec3<f32>(1.0));
}
