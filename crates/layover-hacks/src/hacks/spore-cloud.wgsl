// Spore Cloud: competing cellular-automaton colonies and age-limited Life
// clouds blooming, colliding and fading across the dark.
// After xscreensaver's Cloudlife (Don Marti, 2003) and Petri (Dan Bornstein, 1997).
//
// 4-channel Rgba16Float state encoding (toroidal repeat integer-grid cells):
//   x: cell state (0.0 = empty agar, +1..+MAX_AGE = living generation age,
//                  -1..-LYTIC_STEPS = Petri Black Death lytic front or Stage 2 echo)
//   y: strain (0.0..1.0 species hue inherited on birth and carried into vapor)
//   z: cloud  (0.0..1.0 diffused Cloudlife afterglow strictly decayed by g.fade)
//   w: nutrient (0.0..1.0 local agar resource consumed by living cells)

const TICK_HZ: f32 = 10.0;
const LYTIC_STEPS: f32 = 3.0;
const INOC_TICKS: i32 = 10;

fn tex_dims() -> vec2<i32> {
    return vec2<i32>(textureDimensions(state_tex));
}

fn load_wrap(coord: vec2<i32>, dims: vec2<i32>) -> vec4<f32> {
    let w = ((coord % dims) + dims) % dims;
    return textureLoad(state_tex, w, 0);
}

fn stage_index(t: f32) -> u32 {
    return u32(floor(max(t, 0.0) / 36.0)) % 3u;
}

fn max_age_for_stage(stage: u32) -> f32 {
    if (stage == 1u) {
        return 30.0;
    }
    if (stage == 2u) {
        return 20.0;
    }
    return 26.0;
}

fn hue_dist(a: f32, b: f32) -> f32 {
    let d = abs(fract(a) - fract(b));
    return min(d, 1.0 - d);
}

// Balanced 6-stop bioluminescent jewel palette keeping R/G/B channel shares even.
fn spore_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let cobalt = vec3<f32>(0.24, 0.46, 0.96);
    let teal = vec3<f32>(0.14, 0.84, 0.84);
    let jade = vec3<f32>(0.22, 0.90, 0.46);
    let amber = vec3<f32>(1.00, 0.70, 0.14);
    let rose = vec3<f32>(1.00, 0.24, 0.36);
    let orchid = vec3<f32>(0.86, 0.24, 0.86);
    let s = p * 6.0;
    if (s < 1.0) {
        return mix(cobalt, teal, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(teal, jade, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(jade, amber, smoothstep(0.0, 1.0, s - 2.0));
    }
    if (s < 4.0) {
        return mix(amber, rose, smoothstep(0.0, 1.0, s - 3.0));
    }
    if (s < 5.0) {
        return mix(rose, orchid, smoothstep(0.0, 1.0, s - 4.0));
    }
    return mix(orchid, cobalt, smoothstep(0.0, 1.0, s - 5.0));
}

fn periodic_noise(p: vec2<f32>, period: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let ip = max(vec2<i32>(period), vec2<i32>(1));
    let i00 = ((vec2<i32>(i) % ip) + ip) % ip;
    let i10 = (i00 + vec2<i32>(1, 0)) % ip;
    let i01 = (i00 + vec2<i32>(0, 1)) % ip;
    let i11 = (i00 + vec2<i32>(1, 1)) % ip;
    let a = hash21(vec2<f32>(i00));
    let b = hash21(vec2<f32>(i10));
    let c = hash21(vec2<f32>(i01));
    let d = hash21(vec2<f32>(i11));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn toroidal_delta_i(ic: vec2<i32>, center: vec2<i32>, dims: vec2<i32>) -> vec2<i32> {
    var d = ic - center;
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
    return d;
}

// Return 1.0 if `ic` sits inside an inoculation patch for the active regime.
fn patch_seed(
    ic: vec2<i32>,
    dims: vec2<i32>,
    center: vec2<i32>,
    patch_tag: f32,
    stage: u32,
    strain_in: f32,
) -> f32 {
    let d = toroidal_delta_i(ic, center, dims);
    if (abs(d.x) > 5 || abs(d.y) > 5) {
        return 0.0;
    }
    if (stage == 1u) {
        // Compact circular spore dot for Petri colonies.
        let r2 = d.x * d.x + d.y * d.y;
        return select(0.0, 1.0, r2 <= 2);
    }
    if (stage == 2u) {
        // Organic 7x7 cluster for S345/B3 swirling mycelial spirals.
        if (abs(d.x) > 3 || abs(d.y) > 3) {
            return 0.0;
        }
        let r2 = f32(d.x * d.x + d.y * d.y);
        if (r2 > 10.5) {
            return 0.0;
        }
        let h = hash21(vec2<f32>(f32(d.x + 17) + patch_tag * 9.3, f32(d.y + 19) + strain_in * 31.0));
        let density = mix(0.62, 0.36, clamp(r2 / 10.5, 0.0, 1.0));
        return select(0.0, 1.0, h < density);
    }
    // Stage 0 (Cloudlife): lively 9x9 organic Conway soup kernel.
    if (abs(d.x) > 4 || abs(d.y) > 4) {
        return 0.0;
    }
    let r2 = f32(d.x * d.x + d.y * d.y);
    if (r2 > 18.5) {
        return 0.0;
    }
    let h = hash21(vec2<f32>(f32(d.x + 11) + patch_tag * 7.1, f32(d.y + 13) + strain_in * 29.0));
    let density = mix(0.56, 0.34, clamp(r2 / 18.5, 0.0, 1.0));
    return select(0.0, 1.0, h < density);
}

fn step_state(uv: vec2<f32>, _p: vec2<f32>, t: f32) -> vec4<f32> {
    let dims = tex_dims();
    let ic = clamp(vec2<i32>(floor(uv * vec2<f32>(dims))), vec2<i32>(0), dims - vec2<i32>(1));
    let stage = stage_index(t);
    let max_age = max_age_for_stage(stage);

    if (g.frame < 0.5) {
        let n_init = i32(clamp(round(aspect() * 4.4), 7.0, 16.0));
        var state_x = 0.0;
        var strain = 0.0;
        for (var i: i32 = 0; i < 16; i = i + 1) {
            if (i >= n_init) {
                break;
            }
            let fi = f32(i);
            let h = hash22(vec2<f32>(fi * 7.13 + g.seed * 41.0, g.seed * 19.7 + fi * 3.1));
            let cx = i32(floor(((fi + 0.12 + 0.76 * h.x) / f32(n_init)) * f32(dims.x)));
            let cy = i32(floor((0.14 + 0.72 * h.y) * f32(dims.y)));
            let center = vec2<i32>(clamp(cx, 0, dims.x - 1), clamp(cy, 0, dims.y - 1));
            let s_hue = fract(fi / f32(n_init) + h.x * 0.08 + g.seed * 1.7);
            let hit = patch_seed(ic, dims, center, fi + g.seed * 13.0, stage, s_hue);
            if (hit > 0.5) {
                state_x = 1.0;
                strain = s_hue;
            }
        }
        return vec4<f32>(state_x, strain, select(0.0, 0.55, state_x > 0.5), 1.0);
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

    // 1. Continuous Cloudlife vapor diffusion & exponential real-time decay (every step).
    let card_cloud = (nb[1].z + nb[3].z + nb[5].z + nb[7].z) * 0.25;
    var cloud = mix(c.z, card_cloud, clamp(g.dt * 3.2, 0.0, 0.45)) * g.fade;

    // Preserve and softly blend strain hues along diffusing vapor on empty cells.
    var strain = c.y;
    if (abs(c.x) < 0.5 && c.z < 0.06) {
        var hue_vec = vec2<f32>(cos(c.y * TAU), sin(c.y * TAU)) * max(c.z, 0.005);
        for (var idx: i32 = 1; idx <= 7; idx = idx + 2) {
            let n = nb[idx];
            if (n.z > 0.03 || n.x > 0.5) {
                let w_h = max(n.z, select(0.0, 0.25, n.x > 0.5));
                hue_vec = hue_vec + vec2<f32>(cos(n.y * TAU), sin(n.y * TAU)) * w_h;
            }
        }
        if (length(hue_vec) > 1e-4) {
            strain = fract(atan2(hue_vec.y, hue_vec.x) / TAU);
        }
    }

    // 2. Continuous agar nutrient consumption and recovery.
    var nutrient = c.w;
    if (c.x > 0.5) {
        var drain = 0.20;
        if (stage == 1u) {
            drain = 0.30;
        } else if (stage == 2u) {
            drain = 0.24;
        }
        nutrient = max(0.0, nutrient - g.dt * drain);
    } else if (c.x < -0.5) {
        nutrient = min(0.65, nutrient + g.dt * 0.35);
    } else {
        nutrient = min(1.0, nutrient + g.dt * 0.22);
    }

    // 3. Discrete cellular automaton tick at TICK_HZ (framerate-independent).
    let tick_now = i32(floor(t * TICK_HZ + 0.02));
    let tick_prev = i32(floor(max(t - g.dt, 0.0) * TICK_HZ + 0.02));
    let do_tick = (tick_now > tick_prev) || (g.dt >= (0.99 / TICK_HZ));
    var next_x = c.x;

    if (do_tick) {
        let stage_prev = stage_index(max(t - g.dt, 0.0));
        var n_alive: i32 = 0;
        var n_active_petri: i32 = 0;
        var ortho_alive: f32 = 0.0;
        var diag_alive: f32 = 0.0;
        var ortho_lytic: f32 = 0.0;
        var diag_lytic: f32 = 0.0;
        var pick_strain = strain;
        var pick_weight = 0.0;
        var has_rival = false;

        let tick_f = f32(tick_now % 4096);
        let rnd_cell = hash22(vec2<f32>(ic) + vec2<f32>(tick_f * 0.37 + g.seed * 53.0, tick_f * 0.61 + g.seed * 17.0));

        for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
            for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
                if (dx == 0 && dy == 0) {
                    continue;
                }
                let n = nb[(dy + 1) * 3 + (dx + 1)];
                let is_ortho = (dx == 0 || dy == 0);
                if (n.x > 0.5) {
                    n_alive = n_alive + 1;
                    if (n.x <= 22.5) {
                        n_active_petri = n_active_petri + 1;
                        if (is_ortho) {
                            ortho_alive = ortho_alive + 1.0;
                        } else {
                            diag_alive = diag_alive + 1.0;
                        }
                    }
                    let nh = hash11(f32((dx + 2) * 7 + (dy + 2) * 13) + tick_f * 0.29 + rnd_cell.x * 19.0);
                    let w_pick = select(0.55, 1.0, is_ortho) * (0.4 + nh);
                    if (w_pick > pick_weight) {
                        if (pick_weight > 0.0 && hue_dist(n.y, pick_strain) > 0.09) {
                            has_rival = true;
                        }
                        pick_weight = w_pick;
                        pick_strain = n.y;
                    } else if (hue_dist(n.y, pick_strain) > 0.09) {
                        has_rival = true;
                    }
                } else if (stage == 1u && n.x < -0.5 && n.x > -2.5) {
                    if (is_ortho) {
                        ortho_lytic = ortho_lytic + 1.0;
                    } else {
                        diag_lytic = diag_lytic + 1.0;
                    }
                }
            }
        }
        let has_lytic = (ortho_lytic + diag_lytic) > 0.5;
        let per_org = vec2<f32>(max(round(aspect() * 7.0), 5.0), 7.0);
        let org = periodic_noise(uv * per_org + vec2<f32>(g.seed * 11.0, t * 0.04), per_org);

        if (c.x < -0.5) {
            // Lytic clearing front (Stage 1) or fading echo (Stage 2) stepping -1 -> -2 -> -3 -> 0.
            let step_down = c.x - 1.0;
            next_x = select(0.0, step_down, step_down >= -LYTIC_STEPS);
            if (stage == 1u) {
                cloud = cloud * 0.62;
            }
        } else if (c.x > 0.5) {
            let lytic_p = clamp((ortho_lytic * 0.72 + diag_lytic * 0.23) * (0.62 + 0.72 * org), 0.0, 0.94);
            if (stage == 1u && has_lytic && c.x > 2.5 && rnd_cell.x < lytic_p) {
                next_x = -1.0;
                cloud = max(cloud, 0.40);
            } else if (stage == 0u) {
                // Cloudlife: Conway survival with finite age and nutrient gating.
                if ((n_alive == 2 || n_alive == 3) && c.x < max_age && nutrient > 0.04) {
                    next_x = c.x + 1.0;
                } else {
                    next_x = 0.0;
                    cloud = max(cloud, 0.78);
                }
            } else if (stage == 1u) {
                // Petri: mold persists until max_age or nutrient starvation, with rare lytic mutation.
                if (c.x >= 18.0 && rnd_cell.y < 0.0012) {
                    next_x = -1.0;
                } else if (c.x < max_age && nutrient > 0.02) {
                    next_x = c.x + 1.0;
                } else {
                    next_x = 0.0;
                    cloud = max(cloud, 0.36);
                }
            } else {
                // Stage 2: Living on the Edge (S345/B3) swirling spirals -> fading echo.
                if (n_alive >= 3 && n_alive <= 5 && c.x < max_age && nutrient > 0.04) {
                    next_x = c.x + 1.0;
                } else {
                    next_x = -1.0;
                    cloud = max(cloud, 0.62);
                }
            }
        } else {
            // Empty agar cell: test birth according to active regime.
            var born = false;
            if (stage == 0u) {
                born = (n_alive == 3) && (nutrient > 0.14);
            } else if (stage == 1u) {
                if (n_active_petri > 0 && nutrient > 0.14 && !has_lytic) {
                    let spread = (ortho_alive * 1.0 + diag_alive * 0.32) * (0.55 + 0.85 * org);
                    let inhib = select(1.0, 0.14, has_rival);
                    let p_birth = clamp(spread * 0.34 * inhib * smoothstep(0.12, 0.58, nutrient), 0.0, 0.92);
                    born = rnd_cell.x < p_birth;
                }
            } else {
                // Stage 2: Living on the Edge birth (n_alive == 3) on clean nutrient-ready agar.
                born = (n_alive == 3) && (nutrient > 0.16);
            }

            if (born) {
                next_x = 1.0;
                let mut_delta = select(0.0, (rnd_cell.y - 0.5) * 0.024, rnd_cell.y < 0.08);
                strain = fract(pick_strain + mut_delta);
                cloud = max(cloud, 0.65);
            }
        }

        // Periodic spore / soup inoculations (plus starter burst on stage switches).
        let inoc_now = tick_now / INOC_TICKS;
        let inoc_prev = tick_prev / INOC_TICKS;
        let stage_switched = stage != stage_prev;
        if (inoc_now > inoc_prev || stage_switched) {
            let slot = f32(inoc_now) + select(0.0, 0.5, stage_switched);
            let mult = select(1.35, 3.2, stage_switched);
            let n_drop = i32(clamp(round(aspect() * mult), 3.0, 12.0));
            for (var b: i32 = 0; b < 12; b = b + 1) {
                if (b >= n_drop) {
                    break;
                }
                let fb = f32(b);
                let h = hash22(vec2<f32>(slot * 13.7 + fb * 5.3, g.seed * 37.1 + fb * 9.7));
                let fx = fract((fb + 0.14 + 0.72 * h.x) / f32(n_drop) + slot * 0.381966 + g.seed);
                let fy = fract(0.14 + 0.72 * h.y + slot * 0.618034 + fb * 0.27);
                let center = vec2<i32>(
                    clamp(i32(floor(fx * f32(dims.x))), 0, dims.x - 1),
                    clamp(i32(floor(fy * f32(dims.y))), 0, dims.y - 1),
                );
                let s_hue = fract(slot * 0.23 + fb * 0.29 + h.x * 0.17 + g.seed * 1.9);
                let hit = patch_seed(ic, dims, center, slot * 7.3 + fb, stage, s_hue);
                if (hit > 0.5 && abs(next_x) < 0.5 && nutrient > 0.24) {
                    next_x = 1.0;
                    strain = s_hue;
                    cloud = max(cloud, 0.65);
                }
            }
            // In Petri stage, drop two Black Death lytic triggers onto mature colonies.
            if (stage == 1u) {
                for (var lb: i32 = 0; lb < 2; lb = lb + 1) {
                    let hl = hash22(vec2<f32>(slot * 29.3 + f32(lb) * 11.7, g.seed * 43.7 + f32(lb) * 7.1));
                    let lc = vec2<i32>(
                        clamp(i32(floor(hl.x * f32(dims.x))), 0, dims.x - 1),
                        clamp(i32(floor(hl.y * f32(dims.y))), 0, dims.y - 1),
                    );
                    let dl = toroidal_delta_i(ic, lc, dims);
                    if ((dl.x * dl.x + dl.y * dl.y) <= 2 && next_x > 5.0) {
                        next_x = -1.0;
                        cloud = max(cloud, 0.50);
                    }
                }
            }
        }
    }

    // Living young edges top up Cloudlife vapor softly.
    if (next_x > 0.5) {
        let young_emit = (1.0 - smoothstep(1.0, max_age * 0.60, next_x)) * 0.72;
        cloud = clamp(max(cloud, young_emit), 0.0, 1.0);
    }

    return vec4<f32>(next_x, fract(strain), clamp(cloud, 0.0, 1.0), clamp(nutrient, 0.0, 1.0));
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let dims = tex_dims();
    let dims_f = vec2<f32>(dims);
    let asp = aspect();
    let stage = stage_index(t);
    let max_age = max_age_for_stage(stage);

    // Gentle monotonic toroidal drift so even quiet zones traverse the panel.
    let drift = vec2<f32>(t * 0.036 / asp, t * 0.012 + 0.006 * sin(t * 0.17));
    let uv = fract(state_uv(p) + drift);
    let tc = uv * dims_f - vec2<f32>(0.5);

    let center_i = vec2<i32>(floor(tc + 0.5));
    let base = vec2<i32>(floor(tc));
    let f_bilin = tc - vec2<f32>(base);
    let f_cell = tc - vec2<f32>(center_i);

    // Single 3x3 neighborhood load covers both 2x2 bilinear vapor and smooth organic contours.
    var nb: array<vec4<f32>, 9>;
    var k: i32 = 0;
    for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
        for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
            nb[k] = load_wrap(center_i + vec2<i32>(ox, oy), dims);
            k = k + 1;
        }
    }

    // 1. Bilinear Cloudlife vapor with circular hue interpolation (safely below LIT).
    let bx0 = base.x - center_i.x + 1;
    let by0 = base.y - center_i.y + 1;
    var cloud_sum = 0.0;
    var hue_vec = vec2<f32>(0.0);
    for (var qy: i32 = 0; qy <= 1; qy = qy + 1) {
        for (var qx: i32 = 0; qx <= 1; qx = qx + 1) {
            let s = nb[(by0 + qy) * 3 + (bx0 + qx)];
            let w = mix(1.0 - f_bilin.x, f_bilin.x, f32(qx)) * mix(1.0 - f_bilin.y, f_bilin.y, f32(qy));
            let c_val = clamp(s.z, 0.0, 1.0);
            cloud_sum = cloud_sum + c_val * w;
            let ang = s.y * TAU;
            hue_vec = hue_vec + vec2<f32>(cos(ang), sin(ang)) * (c_val * w);
        }
    }
    let cloud_hue = select(0.0, fract(atan2(hue_vec.y, hue_vec.x) / TAU), length(hue_vec) > 1e-5);
    let mist_per = vec2<f32>(max(round(asp * 20.0), 10.0), 20.0);
    let mist = 0.78 + 0.36 * periodic_noise(uv * mist_per + vec2<f32>(t * 0.22, -t * 0.15), mist_per);
    let vapor = smoothstep(0.03, 0.62, cloud_sum) * mist * 0.24;
    var col = spore_palette(cloud_hue + t * 0.008) * vapor;

    // 2. Smooth 3x3 metaball tissue contour + rival-strain territorial clefts.
    var best_w = 0.0;
    var dom_strain = 0.0;
    for (var j: i32 = 0; j < 9; j = j + 1) {
        let s = nb[j];
        if (s.x > 0.5) {
            let ox = f32((j % 3) - 1);
            let oy = f32((j / 3) - 1);
            let dp = f_cell - vec2<f32>(ox, oy);
            let k_w = exp(-dot(dp, dp) * 4.2);
            if (k_w > best_w) {
                best_w = k_w;
                dom_strain = s.y;
            }
        }
    }

    var same_field = 0.0;
    var rival_field = 0.0;
    var rim_acc = 0.0;
    var interior_acc = 0.0;
    var age_acc = 0.0;
    var lytic_field = 0.0;
    var lytic_hue_vec = vec2<f32>(0.0);

    for (var j: i32 = 0; j < 9; j = j + 1) {
        let s = nb[j];
        let ox = f32((j % 3) - 1);
        let oy = f32((j / 3) - 1);
        let dp = f_cell - vec2<f32>(ox, oy);
        let d2 = dot(dp, dp);
        let kern = exp(-d2 * 4.0);
        if (s.x > 0.5) {
            if (hue_dist(s.y, dom_strain) < 0.09) {
                same_field = same_field + kern;
                let af = clamp((s.x - 1.0) / max(max_age - 1.0, 1.0), 0.0, 1.0);
                let rim_s = 1.0 - smoothstep(0.0, 0.28, af);
                let int_s = 1.0 - smoothstep(0.55, 1.0, af);
                rim_acc = rim_acc + kern * rim_s;
                interior_acc = interior_acc + kern * int_s;
                age_acc = age_acc + kern * af;
            } else {
                rival_field = rival_field + kern;
            }
        } else if (s.x < -0.5) {
            let l_fade = smoothstep(-LYTIC_STEPS - 0.3, -0.7, s.x);
            let lk = exp(-d2 * 3.8) * l_fade;
            lytic_field = lytic_field + lk;
            let lang = s.y * TAU;
            lytic_hue_vec = lytic_hue_vec + vec2<f32>(cos(lang), sin(lang)) * lk;
        }
    }

    if (same_field > 0.05) {
        let net_field = same_field - rival_field * 0.95;
        let aa_f = max(0.05, 0.14 * dims_f.y / max(g.target_size.y, 1.0));
        let thresh = select(0.40, 0.36, stage == 1u);
        let tissue_cov = smoothstep(thresh - aa_f, thresh + aa_f, net_field);

        let rim_frac = clamp(rim_acc / max(same_field, 1e-4), 0.0, 1.0);
        let int_frac = clamp(interior_acc / max(same_field, 1e-4), 0.0, 1.0);
        let age_avg = clamp(age_acc / max(same_field, 1e-4), 0.0, 1.0);

        // Subtle cellular spore modulation in Stage 0 & 2; silky concentric Petri ripples in Stage 1.
        let cell_grain = select(
            1.0 - 0.16 * smoothstep(0.04, 0.24, dot(f_cell, f_cell)),
            1.0,
            stage == 1u,
        );
        let ripple = 0.62 + 0.38 * cos(age_avg * 18.0 - t * 2.6 + uv.x * 16.0);
        let contact_glow = smoothstep(0.08, 0.36, min(same_field, rival_field)) * tissue_cov;

        // Bright advancing front rim; mature colony interior stays under LIT (0.15 post-care).
        let base_col = spore_palette(dom_strain + age_avg * 0.07 + t * 0.008);
        let rim_col = mix(base_col, vec3<f32>(0.94, 0.97, 1.0), 0.32);
        let body_col = mix(base_col * 0.78, rim_col, rim_frac);
        let lum = (rim_frac * 0.80 + int_frac * (0.15 + 0.07 * ripple)) * cell_grain;

        col = col + body_col * (tissue_cov * lum) + rim_col * (contact_glow * 0.45);
    }

    if (lytic_field > 0.18) {
        let echo_cov = smoothstep(0.30, 0.62, lytic_field);
        let l_hue = select(0.0, fract(atan2(lytic_hue_vec.y, lytic_hue_vec.x) / TAU), length(lytic_hue_vec) > 1e-5);
        if (stage == 1u) {
            // Petri Black Death: brief deep violet lysis rim clearing mature mold.
            let lysis_col = mix(vec3<f32>(0.36, 0.14, 0.62), spore_palette(l_hue + 0.5), 0.25);
            col = col + lysis_col * (echo_cov * 0.34);
        } else {
            // Stage 2: luminous mycelial echo wake trailing active S345/B3 spirals.
            let echo_col = spore_palette(l_hue + 0.04 + t * 0.008);
            col = col + echo_col * (echo_cov * 0.30);
        }
    }

    // Soft highlight roll-off keeping incandescent rims crisp without clipping care.max_white.
    col = col / (vec3<f32>(1.0) + col * 0.14);
    return clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
}
