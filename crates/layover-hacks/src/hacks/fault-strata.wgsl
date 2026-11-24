// Fault Strata: growing crystalline cracks halting in T-junctions with
// one-sided watercolor sand strata drifting across the dark.
// After xscreensaver's Substrate (Jared Tarbell, 2003; Mike Kershaw, 2004).

const STEP_LEN: f32 = 0.90;
const SEED_PERIOD: f32 = 3.37;
const BRANCH_RATE: f32 = 0.18;
const SAND_REACH: f32 = 0.28;
const WALL_MIN: f32 = 0.015;
const COLLIDE_MIN: f32 = 0.045;

fn wrap_tau(a: f32) -> f32 {
    return fract(a / TAU) * TAU;
}

fn tex_dims() -> vec2<i32> {
    return vec2<i32>(textureDimensions(state_tex));
}

fn load_wrap(coord: vec2<i32>, dims: vec2<i32>) -> vec4<f32> {
    let w = ((coord % dims) + dims) % dims;
    return textureLoad(state_tex, w, 0);
}

fn stage_index(t: f32) -> u32 {
    return u32(floor(max(t, 0.0) / 45.0)) % 3u;
}

// Balanced 6-stop nocturnal jewel palette keeping R/G/B channel shares even.
fn strata_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let lapis = vec3<f32>(0.16, 0.48, 0.96);
    let cyan = vec3<f32>(0.14, 0.86, 0.88);
    let jade = vec3<f32>(0.22, 0.90, 0.56);
    let ochre = vec3<f32>(0.96, 0.68, 0.18);
    let carnelian = vec3<f32>(0.96, 0.28, 0.46);
    let amethyst = vec3<f32>(0.68, 0.30, 0.96);
    let s = p * 6.0;
    if (s < 1.0) {
        return mix(lapis, cyan, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(cyan, jade, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(jade, ochre, smoothstep(0.0, 1.0, s - 2.0));
    }
    if (s < 4.0) {
        return mix(ochre, carnelian, smoothstep(0.0, 1.0, s - 3.0));
    }
    if (s < 5.0) {
        return mix(carnelian, amethyst, smoothstep(0.0, 1.0, s - 4.0));
    }
    return mix(amethyst, lapis, smoothstep(0.0, 1.0, s - 5.0));
}

fn pick_mode_code(stage: u32, r: f32) -> f32 {
    var curve_p = 0.08;
    if (stage == 1u) {
        curve_p = 0.88;
    } else if (stage == 2u) {
        curve_p = 0.10;
    }
    if (r < curve_p * 0.5) {
        return 2.0;
    }
    if (r < curve_p) {
        return 3.0;
    }
    return 1.0;
}

fn tip_curvature(tip_x: f32, dims_y: f32, stage: u32) -> f32 {
    let mode_idx = clamp(i32(floor(-tip_x)), 1, 3);
    if (mode_idx == 1) {
        return 0.0;
    }
    let sign = select(-1.0, 1.0, mode_idx == 2);
    let k = select(0.78, 2.35, stage == 1u);
    return sign * k * STEP_LEN / max(dims_y, 1.0);
}

fn seed_angle(stage: u32, h: vec2<f32>) -> f32 {
    if (stage == 0u) {
        // Intersecting rectilinear angles with varied regional tilts.
        if (h.x < 0.72) {
            let base_q = floor(h.y * 4.0) * (PI * 0.5);
            let tilt = (fract(h.x * 13.7) - 0.5) * 0.44;
            return wrap_tau(base_q + tilt);
        }
        return wrap_tau(h.y * TAU);
    }
    if (stage == 2u) {
        // Crystalline cleavage planes aligned near 60-degree crystal axes.
        let base_h = floor(h.y * 6.0) * (PI / 3.0);
        let tilt = (h.x - 0.5) * 0.22;
        return wrap_tau(base_h + tilt);
    }
    return wrap_tau(h.y * TAU);
}

fn branch_delta_angle(stage: u32, h: f32) -> f32 {
    if (stage == 0u) {
        return PI * 0.5 + (h - 0.5) * 0.07;
    }
    if (stage == 1u) {
        return PI * 0.5 + (h - 0.5) * 0.12;
    }
    // Stage 2: 75% +/-60 deg crystal cleavage, 25% +/-90 deg.
    if (fract(h * 7.3) < 0.75) {
        return PI / 3.0 + (h - 0.5) * 0.07;
    }
    return PI * 0.5 + (h - 0.5) * 0.07;
}

fn seed_pair_coords(
    idx: i32,
    count: i32,
    tag: f32,
    dims: vec2<i32>,
    stage: u32,
) -> vec4<f32> {
    let fi = f32(idx);
    let h0 = hash22(vec2<f32>(fi * 7.13 + tag * 13.7 + g.seed * 41.0, g.seed * 19.7 + fi * 3.1 + tag));
    let h1 = hash22(vec2<f32>(fi * 11.7 + tag * 5.9 + g.seed * 23.0, tag * 17.3 + fi * 4.3));
    let fx = (fi + 0.16 + 0.68 * h0.x) / f32(count);
    let fy = 0.14 + 0.72 * h0.y;
    let sc = vec2<i32>(
        clamp(i32(floor(fx * f32(dims.x))), 0, dims.x - 1),
        clamp(i32(floor(fy * f32(dims.y))), 0, dims.y - 1),
    );
    let theta = seed_angle(stage, h1);
    return vec4<f32>(f32(sc.x), f32(sc.y), theta, fract(fi / f32(count) + h1.x * 0.37 + g.seed * 2.1));
}

fn is_clear_texel(v: vec4<f32>) -> bool {
    return v.x <= WALL_MIN && v.x >= -0.5;
}

// 4-channel Rgba16Float state encoding:
//   Active tip (x < -0.5): x = -(mode + hue), y = theta, z = ox, w = oy
//   Passive wall (x > 0.015): x = intensity, y = theta, z = perp_offset, w = hue
//   Empty / Sand (x == 0.0): x = 0.0, y = theta_sand, z = sand, w = sand_hue
fn step_state(uv: vec2<f32>, _p: vec2<f32>, t: f32) -> vec4<f32> {
    let dims = tex_dims();
    let ic = clamp(vec2<i32>(floor(uv * vec2<f32>(dims))), vec2<i32>(0), dims - vec2<i32>(1));
    let stage = stage_index(t);

    if (g.frame < 0.5) {
        let n_init = i32(clamp(round(aspect() * 1.65), 3.0, 6.0));
        for (var i: i32 = 0; i < 6; i = i + 1) {
            if (i >= n_init) {
                break;
            }
            let sp = seed_pair_coords(i, n_init, 0.0, dims, stage);
            let sc = vec2<i32>(i32(sp.x), i32(sp.y));
            let theta = sp.z;
            let hue = clamp(sp.w, 0.02, 0.98);
            let dir = vec2<f32>(cos(theta), sin(theta));
            let sc2 = ((sc - vec2<i32>(round(dir))) % dims + dims) % dims;
            if (ic.x == sc.x && ic.y == sc.y) {
                let m = pick_mode_code(stage, hash11(f32(i) * 5.7 + g.seed * 31.3));
                return vec4<f32>(-(m + hue), theta, 0.0, 0.0);
            }
            if ((sc2.x != sc.x || sc2.y != sc.y) && ic.x == sc2.x && ic.y == sc2.y) {
                let m = pick_mode_code(stage, hash11(f32(i) * 9.3 + g.seed * 17.1));
                return vec4<f32>(-(m + hue), wrap_tau(theta + PI), 0.0, 0.0);
            }
        }
        return vec4<f32>(0.0);
    }

    var nb: array<vec4<f32>, 9>;
    var k: i32 = 0;
    var has_tip = false;
    var max_nb_wall: f32 = 0.0;
    for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
        for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
            let v = load_wrap(ic + vec2<i32>(dx, dy), dims);
            nb[k] = v;
            if (v.x < -0.5) {
                has_tip = true;
            }
            if (v.x > WALL_MIN) {
                max_nb_wall = max(max_nb_wall, v.x);
            }
            k = k + 1;
        }
    }

    let c = nb[4];
    let dims_y = f32(dims.y);

    // Case 1: Active tip at ic either advances sub-texel or leaves a passive wall.
    if (c.x < -0.5) {
        let dir = vec2<f32>(cos(c.y), sin(c.y));
        let r = vec2<f32>(c.z, c.w) + STEP_LEN * dir;
        let delta = vec2<i32>(floor(r + 0.5));
        if (delta.x == 0 && delta.y == 0) {
            let next_theta = wrap_tau(c.y + tip_curvature(c.x, dims_y, stage));
            return vec4<f32>(c.x, next_theta, r.x, r.y);
        }
        let nrm = vec2<f32>(-dir.y, dir.x);
        let perp_off = clamp(dot(vec2<f32>(c.z, c.w), nrm), -0.71, 0.71);
        let hue = clamp(fract(-c.x), 0.02, 0.98);
        return vec4<f32>(1.0, c.y, perp_off, hue);
    }

    // Case 2: Check whether an 8-neighbor active tip steps into ic.
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
                    let weld = max(c.x * g.fade, min(1.0, c.x + 0.20));
                    return vec4<f32>(weld, c.y, c.z, c.w);
                }
                let nrm_n = vec2<f32>(-dir_n.y, dir_n.x);
                let perp_n = clamp(dot(new_o, nrm_n), -0.71, 0.71);
                let hue_n = clamp(fract(-n.x), 0.02, 0.98);
                return vec4<f32>(0.90, n.y, perp_n, hue_n);
            }
            let next_theta = wrap_tau(n.y + tip_curvature(n.x, dims_y, stage));
            return vec4<f32>(n.x, next_theta, new_o.x, new_o.y);
        }
    }

    // Case 3: Passive crack wall fades cleanly on real time.
    if (c.x > WALL_MIN) {
        let life = c.x * g.fade;
        if (life > WALL_MIN) {
            return vec4<f32>(life, c.y, c.z, c.w);
        }
    }

    // Case 4a: Periodic seed injection across quiet regions.
    let slot_now = floor((t + 1e-4) / SEED_PERIOD);
    let slot_prev = floor((max(t - g.dt, 0.0) + 1e-4) / SEED_PERIOD);
    if (slot_now > slot_prev && !has_tip && max_nb_wall < 0.10) {
        let n_seeds = i32(clamp(round(aspect() * 0.55), 1.0, 2.0));
        for (var b: i32 = 0; b < 2; b = b + 1) {
            if (b >= n_seeds) {
                break;
            }
            let sp = seed_pair_coords(b, n_seeds, slot_now, dims, stage);
            let sc = vec2<i32>(i32(sp.x), i32(sp.y));
            let theta = sp.z;
            let hue = clamp(sp.w, 0.02, 0.98);
            let dir = vec2<f32>(cos(theta), sin(theta));
            let sc2 = ((sc - vec2<i32>(round(dir))) % dims + dims) % dims;
            if (ic.x == sc.x && ic.y == sc.y) {
                let m = pick_mode_code(stage, hash11(slot_now * 7.3 + f32(b) * 11.1 + g.seed * 19.0));
                return vec4<f32>(-(m + hue), theta, 0.0, 0.0);
            }
            if ((sc2.x != sc.x || sc2.y != sc.y) && ic.x == sc2.x && ic.y == sc2.y) {
                let m = pick_mode_code(stage, hash11(slot_now * 5.9 + f32(b) * 17.7 + g.seed * 29.0));
                return vec4<f32>(-(m + hue), wrap_tau(theta + PI), 0.0, 0.0);
            }
        }
    }

    // Case 4b: Perpendicular / crystalline branching off living walls.
    if (!has_tip) {
        let f_u = u32(max(g.frame, 0.0));
        let frame_tag = vec2<f32>(f32(f_u % 997u) * 0.37, f32((f_u / 997u) % 997u) * 0.53);
        let h_rnd = hash22(vec2<f32>(ic) + frame_tag + vec2<f32>(g.seed * 73.1, g.seed * 37.9));
        let branch_p = BRANCH_RATE * state_texel().y * g.dt;
        if (h_rnd.x < branch_p) {
            for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
                for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
                    if (dx == 0 && dy == 0) {
                        continue;
                    }
                    let n = nb[(dy + 1) * 3 + (dx + 1)];
                    if (n.x <= 0.38 || n.x >= 0.88) {
                        continue;
                    }
                    let to_me = normalize(vec2<f32>(-f32(dx), -f32(dy)));
                    let delta_a = branch_delta_angle(stage, h_rnd.y);
                    for (var s_idx: i32 = 0; s_idx < 2; s_idx = s_idx + 1) {
                        let sign = select(-1.0, 1.0, s_idx == 0);
                        let b_theta = wrap_tau(n.y + sign * delta_a);
                        let bdir = vec2<f32>(cos(b_theta), sin(b_theta));
                        if (dot(to_me, bdir) > 0.76) {
                            let bperp = vec2<f32>(-bdir.y, bdir.x);
                            let fwd1 = load_wrap(ic + vec2<i32>(round(bdir)), dims);
                            let fwd2 = load_wrap(ic + vec2<i32>(round(bdir * 2.0)), dims);
                            let fwd3 = load_wrap(ic + vec2<i32>(round(bdir * 3.0)), dims);
                            let side1a = load_wrap(ic + vec2<i32>(round(bperp)), dims);
                            let side1b = load_wrap(ic - vec2<i32>(round(bperp)), dims);
                            let side2a = load_wrap(ic + vec2<i32>(round(bperp * 2.0)), dims);
                            let side2b = load_wrap(ic - vec2<i32>(round(bperp * 2.0)), dims);
                            if (is_clear_texel(fwd1)
                                && is_clear_texel(fwd2)
                                && is_clear_texel(fwd3)
                                && is_clear_texel(side1a)
                                && is_clear_texel(side1b)
                                && is_clear_texel(side2a)
                                && is_clear_texel(side2b))
                            {
                                let h2 = hash11(h_rnd.y * 53.1 + f32(dx * 5 + dy * 11) + g.seed * 19.3);
                                let new_hue = clamp(fract(n.w + 0.08 + 0.16 * h2), 0.02, 0.98);
                                let m = pick_mode_code(stage, fract(h_rnd.y * 19.7));
                                return vec4<f32>(-(m + new_hue), b_theta, 0.0, 0.0);
                            }
                        }
                    }
                }
            }
        }
    }

    // Case 4c: One-sided Sand Painter directional advection.
    var best_score: f32 = 0.0;
    var best_theta: f32 = 0.0;
    var best_hue: f32 = 0.0;
    for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
        for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
            if (dx == 0 && dy == 0) {
                continue;
            }
            let n = nb[(dy + 1) * 3 + (dx + 1)];
            let to_me = normalize(vec2<f32>(-f32(dx), -f32(dy)));
            var theta_s = 0.0;
            var strength = 0.0;
            var s_hue = n.w;
            if (n.x > 0.12) {
                let side = select(-1.0, 1.0, fract(n.w * 7.13) > 0.5);
                theta_s = wrap_tau(n.y + side * PI * 0.5);
                strength = n.x * 0.96;
            } else if (n.x >= -0.5 && n.x <= WALL_MIN && n.z > 0.015) {
                theta_s = n.y;
                strength = n.z;
            } else {
                continue;
            }
            let sdir = vec2<f32>(cos(theta_s), sin(theta_s));
            let align = dot(to_me, sdir);
            if (align > 0.68) {
                let score = strength * align;
                if (score > best_score) {
                    best_score = score;
                    best_theta = theta_s;
                    best_hue = s_hue;
                }
            }
        }
    }

    if (best_score > 0.0) {
        let sdir = vec2<f32>(cos(best_theta), sin(best_theta));
        let ox = select(1, -1, sdir.x >= 0.0);
        let oy = select(1, -1, sdir.y >= 0.0);
        let wx = abs(sdir.x);
        let wy = abs(sdir.y);
        let w_x = wx * (1.0 - wy);
        let w_y = (1.0 - wx) * wy;
        let w_xy = wx * wy;
        let w_sum = max(w_x + w_y + w_xy, 1e-4);

        let taps = array<vec2<i32>, 3>(vec2<i32>(ox, 0), vec2<i32>(0, oy), vec2<i32>(ox, oy));
        let wts = array<f32, 3>(w_x, w_y, w_xy);
        var pulled = 0.0;
        for (var i: i32 = 0; i < 3; i = i + 1) {
            let off = taps[i];
            let n = nb[(off.y + 1) * 3 + (off.x + 1)];
            let to_me = normalize(vec2<f32>(-f32(off.x), -f32(off.y)));
            var tap_val = 0.0;
            if (n.x > 0.12) {
                let side = select(-1.0, 1.0, fract(n.w * 7.13) > 0.5);
                let th = wrap_tau(n.y + side * PI * 0.5);
                let nd = vec2<f32>(cos(th), sin(th));
                if (dot(to_me, nd) > 0.55) {
                    tap_val = n.x * 0.96;
                }
            } else if (n.x >= -0.5 && n.x <= WALL_MIN && n.z > 0.015) {
                let nd = vec2<f32>(cos(n.y), sin(n.y));
                if (dot(nd, sdir) > 0.55) {
                    tap_val = n.z;
                }
            }
            pulled = pulled + tap_val * wts[i];
        }
        let sand = (pulled / w_sum) * exp(-1.0 / (SAND_REACH * dims_y)) * g.fade;
        if (sand > 0.012) {
            return vec4<f32>(0.0, best_theta, sand, clamp(best_hue, 0.02, 0.98));
        }
    }

    return vec4<f32>(0.0);
}

fn periodic_noise(p: vec2<f32>, period: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let i00 = ((vec2<i32>(i) % vec2<i32>(period)) + vec2<i32>(period)) % vec2<i32>(period);
    let i10 = (i00 + vec2<i32>(1, 0)) % vec2<i32>(period);
    let i01 = (i00 + vec2<i32>(0, 1)) % vec2<i32>(period);
    let i11 = (i00 + vec2<i32>(1, 1)) % vec2<i32>(period);
    let a = hash21(vec2<f32>(i00));
    let b = hash21(vec2<f32>(i10));
    let c = hash21(vec2<f32>(i01));
    let d = hash21(vec2<f32>(i11));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let dims = tex_dims();
    let dims_f = vec2<f32>(dims);
    let drift = vec2<f32>(t * 0.020 / aspect(), t * 0.009 + 0.005 * sin(t * 0.13));
    let uv = fract(state_uv(p) + drift);
    let tc = uv * dims_f - vec2<f32>(0.5);

    // 1. One-sided watercolor sand strata (wall-clamped 2x2 bilinear, skipping active tips).
    let base = vec2<i32>(floor(tc));
    let f = tc - vec2<f32>(base);
    var sq_c: array<vec2<i32>, 4>;
    var sq_s: array<vec4<f32>, 4>;
    var sq_w: array<f32, 4>;
    var idx_sq: i32 = 0;
    for (var oy: i32 = 0; oy <= 1; oy = oy + 1) {
        for (var ox: i32 = 0; ox <= 1; ox = ox + 1) {
            let cc = base + vec2<i32>(ox, oy);
            sq_c[idx_sq] = cc;
            sq_s[idx_sq] = load_wrap(cc, dims);
            sq_w[idx_sq] = mix(1.0 - f.x, f.x, f32(ox)) * mix(1.0 - f.y, f.y, f32(oy));
            idx_sq = idx_sq + 1;
        }
    }

    var sand_sum = 0.0;
    var w_total = 0.0;
    var hue_vec = vec2<f32>(0.0);
    for (var i: i32 = 0; i < 4; i = i + 1) {
        let s = sq_s[i];
        if (s.x < -0.5) {
            continue;
        }
        let cc_i = vec2<f32>(f32(sq_c[i].x), f32(sq_c[i].y));
        var blocked = false;
        if (s.x <= WALL_MIN) {
            for (var j: i32 = 0; j < 4; j = j + 1) {
                let sw = sq_s[j];
                if (sw.x <= WALL_MIN) {
                    continue;
                }
                let wdir = vec2<f32>(cos(sw.y), sin(sw.y));
                let wnrm = vec2<f32>(-wdir.y, wdir.x);
                let lpt = vec2<f32>(f32(sq_c[j].x), f32(sq_c[j].y)) + wnrm * sw.z;
                let dt = dot(tc - lpt, wnrm);
                let dc = dot(cc_i - lpt, wnrm);
                if (dt * dc < 0.0 && abs(dt) < 1.25 && abs(dot(tc - lpt, wdir)) < 1.25) {
                    blocked = true;
                    break;
                }
            }
        }
        if (blocked) {
            continue;
        }
        let w = sq_w[i];
        if (s.x <= WALL_MIN) {
            w_total = w_total + w;
            let val = clamp(s.z, 0.0, 1.0);
            sand_sum = sand_sum + val * w;
            let ang = s.w * TAU;
            hue_vec = hue_vec + vec2<f32>(cos(ang), sin(ang)) * (val * w);
        } else {
            let side = select(-1.0, 1.0, fract(s.w * 7.13) > 0.5);
            let nrm = vec2<f32>(-sin(s.y), cos(s.y));
            let sdir = nrm * side;
            let line_pt = cc_i + nrm * s.z;
            let d_side = dot(tc - line_pt, sdir);
            if (d_side >= -0.20) {
                w_total = w_total + w;
                let side_mask = smoothstep(-0.20, 0.30, d_side);
                let val = clamp(s.x * 0.85, 0.0, 1.0) * side_mask;
                sand_sum = sand_sum + val * w;
                let ang = s.w * TAU;
                hue_vec = hue_vec + vec2<f32>(cos(ang), sin(ang)) * (val * w);
            }
        }
    }

    let sand = select(0.0, sand_sum / w_total, w_total > 1e-4);
    let hue_len = length(hue_vec);
    let sand_hue = select(0.0, fract(atan2(hue_vec.y, hue_vec.x) / TAU), hue_len > 1e-5);
    let period = vec2<f32>(max(round(aspect() * 88.0), 8.0), 88.0);
    let grain = periodic_noise(uv * period, period);
    let grain_mod = 0.84 + 0.28 * grain;
    let strata_wave = 0.54 + 0.46 * pow(0.5 + 0.5 * cos(sand * 9.5 - t * 0.45), 1.35);
    let strata = mix(1.0, strata_wave, smoothstep(0.18, 0.52, sand));
    let sand_soft = smoothstep(0.012, 0.58, sand);
    let sand_col = strata_palette(sand_hue + sand * 0.08 + t * 0.008)
        * (sand_soft * strata * grain_mod * 0.60);

    // 2. Collinear vector crack lines + growing crystal tips (3x3 over round(tc)).
    let center_i = vec2<i32>(round(tc));
    let aa = max(0.22, 0.72 * dims_f.y / max(g.target_size.y, 1.0));
    let hw = 0.36;
    let pearl = vec3<f32>(0.96, 0.94, 0.99);

    var best_crack_val = 0.0;
    var best_crack_col = vec3<f32>(0.0);
    var tip_col = vec3<f32>(0.0);

    for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
        for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
            let ic = center_i + vec2<i32>(ox, oy);
            let c = load_wrap(ic, dims);
            let center = vec2<f32>(f32(ic.x), f32(ic.y));
            if (c.x > WALL_MIN) {
                let dir = vec2<f32>(cos(c.y), sin(c.y));
                let nrm = vec2<f32>(-dir.y, dir.x);
                let line_pt = center + nrm * c.z;
                let rel = tc - line_pt;
                let along = clamp(dot(rel, dir), -0.86, 0.86);
                let d_line = length(rel - dir * along);
                let cov = smoothstep(0.0, 1.0, clamp((hw + aa - d_line) / (2.0 * aa), 0.0, 1.0)) * min(1.0, hw / aa);
                let halo = exp(-d_line * 1.55) * 0.42;
                let life = pow(clamp(c.x, 0.0, 1.0), 0.95);
                let intensity = life * (cov * 1.25 + halo);
                if (intensity > best_crack_val) {
                    best_crack_val = intensity;
                    let c_col = mix(strata_palette(c.w + t * 0.008), pearl, 0.36 * life);
                    best_crack_col = c_col * intensity;
                }
            } else if (c.x < -0.5) {
                let dir = vec2<f32>(cos(c.y), sin(c.y));
                let tip_pt = center + vec2<f32>(c.z, c.w);
                let rel = tc - tip_pt;
                let along = clamp(dot(rel, dir), -0.95, 0.05);
                let d_stem = length(rel - dir * along);
                let stem_cov = smoothstep(0.0, 1.0, clamp((hw + aa - d_stem) / (2.0 * aa), 0.0, 1.0)) * min(1.0, hw / aa);
                let d_tip = length(rel);
                let tip_core = smoothstep(0.0, 1.0, clamp((hw * 1.65 + aa - d_tip) / (2.0 * aa), 0.0, 1.0)) * min(1.0, (hw * 1.65) / aa);
                let tip_aura = exp(-d_tip * 1.55) * 0.80;
                let hue = fract(-c.x);
                let t_base = strata_palette(hue + t * 0.008);
                let needle = mix(t_base, pearl, 0.45) * stem_cov * 1.25
                    + mix(t_base, pearl, 0.72) * (tip_core * 1.45 + tip_aura);
                tip_col = max(tip_col, needle);
            }
        }
    }

    let col = sand_col + best_crack_col + tip_col;
    return col / (vec3<f32>(1.0) + col * 0.14);
}
