// Ember Plume: buoyant curling flames, glowing ember beds and drifting cinders
// rising across the dark.
// After xscreensaver's XFlame (Carsten Haitzler, 1998).
//
// 4-channel Rgba16Float state encoding (stored on toroidal repeat textures):
//   x = heat   (0.0..1.45): fast-rising incandescent flame core temperature
//   y = wisp   (0.0..1.0): outer crimson ember glow and rising flame skirts
//   z = cinder (0.0..1.0): faster-rising swirling sparks shed from crests and beds
//   w = lip    (0.0..1.0): fast-decaying hearth base ignition rim

const BURST_PERIOD: f32 = 4.0;
const BASE_RISE: f32 = 0.36;
const BUOY_RISE: f32 = 0.62;

fn toroidal_delta_p(uv: vec2<f32>, center_uv: vec2<f32>) -> vec2<f32> {
    let d = fract(uv - center_uv + 0.5) - 0.5;
    return vec2<f32>(d.x * aspect(), d.y);
}

// Strictly periodic 2D value noise on [0, 1)^2 (seamless across toroidal wraps).
fn periodic_noise(p: vec2<f32>, period: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let ip = vec2<i32>(period);
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

fn periodic_fbm(uv: vec2<f32>, base_per: vec2<f32>, scroll: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.55;
    var per = base_per;
    var off = scroll;
    for (var i: i32 = 0; i < 3; i = i + 1) {
        let p = vec2<f32>(uv.x * per.x, (1.0 - uv.y) * per.y) + off;
        sum = sum + amp * periodic_noise(p, per);
        per = per * 2.0;
        off = off * 1.85 + vec2<f32>(3.7, 7.1);
        amp = amp * 0.5;
    }
    return sum / 0.9625;
}

fn periodic_ridged_fbm(uv: vec2<f32>, base_per: vec2<f32>, scroll: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.55;
    var per = base_per;
    var off = scroll;
    for (var i: i32 = 0; i < 3; i = i + 1) {
        let p = vec2<f32>(uv.x * per.x, (1.0 - uv.y) * per.y) + off;
        let r = 1.0 - abs(2.0 * periodic_noise(p, per) - 1.0);
        sum = sum + amp * (r * r);
        per = per * 2.0;
        off = off * 1.85 + vec2<f32>(3.7, 7.1);
        amp = amp * 0.5;
    }
    return sum / 0.9625;
}

// Divergence-free periodic curl velocity in world units (canvas heights / sec).
// Using integer wave numbers on uv ensures zero seams across toroidal wraps on any aspect.
fn curl_mode(
    uv: vec2<f32>,
    kx: f32,
    ky: f32,
    amp: f32,
    phase: f32,
    asp: f32,
) -> vec2<f32> {
    let ang = kx * uv.x * TAU + ky * (1.0 - uv.y) * TAU + phase;
    let dpsi = amp * cos(ang);
    let wx = kx * TAU / asp;
    let wy = ky * TAU;
    return vec2<f32>(wy * dpsi, -wx * dpsi);
}

fn curl_vel(uv: vec2<f32>, t: f32) -> vec2<f32> {
    let asp = aspect();
    let s = g.seed * TAU;
    var v = vec2<f32>(0.0);
    // Large buoyant sway
    v = v + curl_mode(uv, max(2.0, round(asp * 1.5)), 1.0, 0.015, t * 0.50 + s, asp);
    v = v + curl_mode(uv, -max(2.0, round(asp * 1.2)), 2.0, 0.012, -t * 0.44 + s * 1.7, asp);
    // Medium curling flame eddies
    v = v + curl_mode(uv, max(3.0, round(asp * 3.2)), -2.0, 0.0080, t * 0.95 + s * 2.3, asp);
    v = v + curl_mode(uv, -max(3.0, round(asp * 2.7)), 3.0, 0.0064, -t * 0.85 + s * 3.1, asp);
    // Lively fine licking tongue eddies
    v = v + curl_mode(uv, max(5.0, round(asp * 5.6)), 4.0, 0.0036, t * 1.68 + s * 4.1, asp);
    v = v + curl_mode(uv, -max(5.0, round(asp * 4.8)), -5.0, 0.0028, -t * 1.48 + s * 5.3, asp);
    return vec2<f32>(v.x, v.y * 0.56);
}

// Convert world velocity (x right, y up in canvas heights/sec) to UV displacement per second.
fn world_to_uv_vel(v_world: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(v_world.x / aspect(), -v_world.y);
}

// Compute hearth emission (heat_inj, wisp_inj, cinder_inj, lip_inj) at UV and time t.
fn hearth_injection(uv: vec2<f32>, t: f32) -> vec4<f32> {
    let asp = aspect();
    let n_hearths = i32(clamp(round(asp * 0.95), 2.0, 4.0));
    var max_heat = 0.0;
    var max_wisp = 0.0;
    var max_cinder = 0.0;
    var max_lip = 0.0;

    for (var wave: i32 = 0; wave < 2; wave = wave + 1) {
        let offset = f32(wave) * 0.5;
        let phase = t / BURST_PERIOD + offset;
        let slot = floor(phase);
        let age = fract(phase);
        let base_env = smoothstep(0.0, 0.14, age) * (1.0 - smoothstep(0.42, 0.84, age));
        if (base_env <= 0.005) {
            continue;
        }

        for (var i: i32 = 0; i < 4; i = i + 1) {
            if (i >= n_hearths) {
                break;
            }
            let fi = f32(i);
            let fw = f32(wave);
            let tag = slot * 19.7 + fw * 53.3 + fi * 11.1 + g.seed * 71.0;
            let h0 = hash22(vec2<f32>(tag, tag * 0.73 + 5.1));
            let h1 = hash22(vec2<f32>(tag * 1.31 + 2.7, fi * 7.9 + slot * 3.7));

            // Stratify horizontally across 32:9 and distribute vertically via golden ratio.
            let x_slot = (fi + 0.14 + 0.72 * h0.x) / f32(n_hearths);
            let x_shift = fract(slot * 0.381966 + fw * 0.5);
            let cx = fract(x_slot + x_shift + age * (0.075 * sign(h1.x - 0.5)));
            let cy = fract(0.14 + (slot * 0.618034 + fw * 0.309017 + fi * 0.27 + h0.y * 0.19));

            let dp = toroidal_delta_p(uv, vec2<f32>(cx, cy));
            let hw = 0.34 + 0.22 * h1.x;
            if (abs(dp.x) > hw * 2.5 || abs(dp.y) > 0.36) {
                continue;
            }

            let nx = dp.x / hw;
            let base_undul = 0.032 * cos(nx * 2.4 + h0.x * TAU)
                + 0.038 * (fbm(vec2<f32>(dp.x * 4.5 + h0.x * 13.0, t * 0.9 + h1.y * 7.0)) - 0.5);
            let dy_up = -dp.y - base_undul;
            let bed_x = exp(-nx * nx * 1.7);

            let turb_wide = fbm(vec2<f32>(dp.x * 4.2 + h0.x * 19.3, -t * 1.8 + h1.y * 11.7 + dy_up * 2.8));
            let turb_sharp = fbm(vec2<f32>(dp.x * 10.5 - t * 1.1 + h1.x * 11.0, -t * 3.1 + dy_up * 5.5 + h0.y * 9.0));
            let turb = turb_wide * 0.52 + turb_sharp * 0.48;
            let gust = 0.80 + 0.20 * sin(age * TAU * 2.4 + h0.x * TAU);

            let hh_up = 0.044 + 0.072 * turb;
            let hh_dn = 0.024 + 0.018 * turb;
            let hh = select(hh_dn, hh_up, dy_up >= 0.0);
            let bed_y = exp(-(dy_up * dy_up) / (hh * hh));

            let tongue_mod = 0.52 + 0.88 * smoothstep(0.24, 0.78, turb_sharp) * (0.65 + 0.55 * turb_wide);
            let flare = clamp(base_env * gust * bed_x * bed_y * tongue_mod, 0.0, 1.45);

            if (flare > 0.008) {
                let h_val = clamp(flare * 1.42, 0.0, 1.45);
                let w_val = clamp(flare * 0.96, 0.0, 1.0);
                max_heat = max(max_heat, h_val);
                max_wisp = max(max_wisp, w_val);

                // Thin electric gas ignition lip strictly along the burning hearth base.
                let lip_band = exp(-pow((dy_up - 0.004) / 0.014, 2.0)) * bed_x * base_env;
                max_lip = max(max_lip, clamp(lip_band * 1.35, 0.0, 1.0));

                // Drifting sparks shed from turbulent flame peaks.
                let sp_f = fbm(vec2<f32>(dp.x * 18.0 - t * 2.8 + h1.x * 23.0, dy_up * 14.0 - t * 4.8));
                let sp_gate = smoothstep(0.54, 0.78, sp_f)
                    * smoothstep(-0.01, 0.03, dy_up)
                    * (1.0 - smoothstep(0.06, 0.16, dy_up));
                let c_val = clamp(sp_gate * base_env * bed_x * 1.65, 0.0, 1.0);
                max_cinder = max(max_cinder, c_val);
            }
        }
    }

    return vec4<f32>(max_heat, max_wisp, max_cinder, max_lip);
}

fn step_state(uv: vec2<f32>, _p: vec2<f32>, t: f32) -> vec4<f32> {
    if (g.frame < 0.5) {
        // Seed crisp rising flame curtains from t = 0 hearths so frame 0 starts alive.
        var heat0 = 0.0;
        var wisp0 = 0.0;
        var cinder0 = 0.0;
        var lip0 = 0.0;

        let asp = aspect();
        let n_hearths = i32(clamp(round(asp * 0.95), 2.0, 4.0));
        for (var wave: i32 = 0; wave < 2; wave = wave + 1) {
            let fw = f32(wave);
            let slot = select(0.0, -1.0, wave == 0);
            let age_w = select(0.50, 0.18, wave == 1);
            let strength = select(0.75, 1.0, wave == 1);
            for (var i: i32 = 0; i < 4; i = i + 1) {
                if (i >= n_hearths) {
                    break;
                }
                let fi = f32(i);
                let tag = slot * 19.7 + fw * 53.3 + fi * 11.1 + g.seed * 71.0;
                let h0 = hash22(vec2<f32>(tag, tag * 0.73 + 5.1));
                let h1 = hash22(vec2<f32>(tag * 1.31 + 2.7, fi * 7.9 + slot * 3.7));
                let x_slot = (fi + 0.14 + 0.72 * h0.x) / f32(n_hearths);
                let x_shift = fract(slot * 0.381966 + fw * 0.5);
                let cx = fract(x_slot + x_shift);
                let cy = fract(0.14 + (slot * 0.618034 + fw * 0.309017 + fi * 0.27 + h0.y * 0.19));
                let dp = toroidal_delta_p(uv, vec2<f32>(cx, cy));
                let hw_base = 0.34 + 0.22 * h1.x;
                let nx0 = dp.x / hw_base;
                let base_undul = 0.032 * cos(nx0 * 2.4 + h0.x * TAU)
                    + 0.038 * (fbm(vec2<f32>(dp.x * 4.5 + h0.x * 13.0, h1.y * 7.0)) - 0.5);
                let dy_up = -dp.y - base_undul - age_w * 0.20;
                if (dy_up > -0.06 && dy_up < 0.60) {
                    let taper = 1.0 - smoothstep(0.0, 0.60, max(dy_up, 0.0)) * 0.68;
                    let hw = hw_base * taper;
                    let sway = 0.048 * sin(dy_up * 11.0 + fi * 2.1 + h0.x * TAU);
                    let nx = (dp.x - sway) / max(hw, 0.04);
                    let env_x = exp(-nx * nx * 1.7);
                    let env_y = smoothstep(-0.05, 0.025, dy_up) * (1.0 - smoothstep(0.10, 0.56, dy_up));
                    let turb_wide = fbm(vec2<f32>(dp.x * 4.2 + h0.x * 19.3, dy_up * 3.2 + h1.y * 11.7));
                    let turb_sharp = fbm(vec2<f32>(dp.x * 10.5 + h1.x * 11.0, dy_up * 5.8 + h0.y * 9.0));
                    let tongue_mod = 0.52 + 0.88 * smoothstep(0.24, 0.78, turb_sharp) * (0.65 + 0.55 * turb_wide);
                    let h_val = clamp(env_x * env_y * tongue_mod * 1.38 * strength, 0.0, 1.45);
                    if (h_val > 0.01) {
                        heat0 = max(heat0, h_val);
                        wisp0 = max(wisp0, clamp(h_val * 0.90, 0.0, 1.0));
                        let sp = smoothstep(0.56, 0.78, fbm(vec2<f32>(dp.x * 15.0, dy_up * 15.0)));
                        cinder0 = max(cinder0, sp * env_x * env_y * 0.95);
                        lip0 = max(lip0, exp(-pow((dy_up - 0.004) / 0.014, 2.0)) * env_x * strength);
                    }
                }
            }
        }
        return vec4<f32>(heat0, wisp0, cinder0, lip0);
    }

    let dt = g.dt;
    let cur = state_sample(uv);

    // 2-step RK2 midpoint backtrace for flame heat and wisp.
    let c0 = curl_vel(uv, t);
    let vy0 = BASE_RISE + BUOY_RISE * clamp(cur.x, 0.0, 1.3) + c0.y;
    let v0_uv = world_to_uv_vel(vec2<f32>(c0.x, vy0));
    let uv_mid = fract(uv - v0_uv * (0.5 * dt));
    let mid_s = state_sample(uv_mid);
    let c_mid = curl_vel(uv_mid, max(t - 0.5 * dt, 0.0));
    let vy_mid = BASE_RISE + BUOY_RISE * clamp(mid_s.x, 0.0, 1.3) + c_mid.y;
    let v_mid_uv = world_to_uv_vel(vec2<f32>(c_mid.x, vy_mid));
    let uv_src = fract(uv - v_mid_uv * dt);

    // Monotonicity-preserving TVD sharpened advection eliminates semi-Lagrangian blur without ringing.
    let d_diff = max(state_texel(), vec2<f32>(0.0045 / aspect(), 0.0045));
    let s_c = state_sample(uv_src);
    let s_l = state_sample(uv_src - vec2<f32>(d_diff.x, 0.0));
    let s_r = state_sample(uv_src + vec2<f32>(d_diff.x, 0.0));
    let s_u = state_sample(uv_src - vec2<f32>(0.0, d_diff.y));
    let s_d = state_sample(uv_src + vec2<f32>(0.0, d_diff.y));
    let avg4 = (s_l + s_r + s_u + s_d) * 0.25;
    let s_min = min(s_c, min(min(s_l, s_r), min(s_u, s_d)));
    let s_max = max(s_c, max(max(s_l, s_r), max(s_u, s_d)));
    let adv = clamp(s_c + (s_c - avg4) * 0.42, s_min, s_max);

    // Faster upward advection for lightweight glowing cinders.
    let c_v0 = world_to_uv_vel(vec2<f32>(c0.x * 1.25, (BASE_RISE + BUOY_RISE * 0.85) * 1.50 + c0.y * 1.25));
    let c_mid_uv = fract(uv - c_v0 * (0.5 * dt));
    let c_c_mid = curl_vel(c_mid_uv, max(t - 0.5 * dt, 0.0));
    let c_vmid = world_to_uv_vel(vec2<f32>(c_c_mid.x * 1.25, (BASE_RISE + BUOY_RISE * 0.85) * 1.50 + c_c_mid.y * 1.25));
    let uv_cinder_src = fract(uv - c_vmid * dt);
    let cinder_adv = state_sample(uv_cinder_src).z;

    // Real-time exponential decay + radiative flame cooling.
    var heat = max(adv.x, 0.0) * g.fade * exp(-dt * (0.14 + 0.30 * max(adv.x, 0.0)));
    var wisp = max(
        max(adv.y, 0.0) * g.fade * exp(-dt * 0.08),
        heat * 0.76 * g.fade,
    );
    var cinder = clamp(cinder_adv * g.fade * exp(-dt * 0.14), 0.0, 1.0);
    // Fast-decaying lip keeps electric cobalt strictly at the burning hearth root.
    var lip = max(adv.w, 0.0) * g.fade * exp(-dt * 1.45);

    // Shed sparks off rising hot flame crests.
    if (heat > 0.30) {
        let sp_pat = sin(uv.x * TAU * 31.0 + t * 8.4) * cos((1.0 - uv.y) * TAU * 17.0 - t * 12.1);
        if (sp_pat > 0.56) {
            cinder = max(cinder, clamp((heat - 0.28) * 1.35, 0.0, 0.95));
        }
    }

    // Framerate-independent hearth injection.
    let inj = hearth_injection(uv, t);
    if (inj.x > 0.005) {
        let k_inj = 1.0 - exp(-dt * 11.0);
        heat = mix(heat, max(heat, inj.x), k_inj);
        wisp = mix(wisp, max(wisp, inj.y), k_inj);
        lip = mix(lip, max(lip, inj.w), k_inj);
    }
    if (inj.z > 0.005) {
        let k_sp = 1.0 - exp(-dt * 15.0);
        cinder = max(cinder, inj.z * k_sp);
    }

    return vec4<f32>(
        clamp(heat, 0.0, 1.45),
        clamp(wisp, 0.0, 1.0),
        clamp(cinder, 0.0, 1.0),
        clamp(lip, 0.0, 1.0),
    );
}

// Authentic incandescent blackbody fire curve with a tight cobalt-blue gas ignition root.
fn fire_palette(temp: f32, lip: f32) -> vec3<f32> {
    let smolder = vec3<f32>(0.42, 0.02, 0.05);
    let crimson = vec3<f32>(0.92, 0.08, 0.05);
    let vermilion = vec3<f32>(1.00, 0.30, 0.04);
    let amber = vec3<f32>(1.00, 0.66, 0.12);
    let white_gold = vec3<f32>(1.00, 0.88, 0.50);

    var flame = smolder;
    if (temp < 0.26) {
        flame = mix(smolder, crimson, smoothstep(0.0, 0.26, temp));
    } else if (temp < 0.54) {
        flame = mix(crimson, vermilion, smoothstep(0.26, 0.54, temp));
    } else if (temp < 0.84) {
        flame = mix(vermilion, amber, smoothstep(0.54, 0.84, temp));
    } else {
        flame = mix(amber, white_gold, smoothstep(0.84, 1.15, temp));
    }

    // Subtle electric cobalt-blue gas root strictly in the thin lower hearth lip.
    let cobalt_base = mix(vec3<f32>(0.14, 0.44, 1.00), vec3<f32>(0.22, 0.72, 1.00), smoothstep(0.30, 0.65, temp));
    let lip_w = smoothstep(0.42, 0.85, lip) * smoothstep(0.10, 0.34, temp) * (1.0 - smoothstep(0.42, 0.68, temp));
    return mix(flame, cobalt_base, clamp(lip_w * 0.72, 0.0, 0.72));
}

// Sparse razor-sharp pinpoint streaking embers rising from hot updrafts.
fn spark_layer(uv: vec2<f32>, t: f32, asp: f32, scale_y: f32, speed: f32, seed_off: f32) -> f32 {
    let grid = vec2<f32>(max(12.0, round(asp * scale_y)), scale_y);
    let sway = sin(uv.y * TAU * 3.0 + t * 1.8 + seed_off) * 0.35;
    let p = vec2<f32>(uv.x * grid.x + sway, (1.0 - uv.y) * grid.y - t * speed);
    let cell = floor(p);
    let f = fract(p) - 0.5;
    let ip = vec2<i32>(grid);
    let cell_w = ((vec2<i32>(cell) % ip) + ip) % ip;
    let rnd = hash22(vec2<f32>(cell_w) + vec2<f32>(seed_off, seed_off * 1.7));
    let keep = hash21(vec2<f32>(cell_w) + vec2<f32>(seed_off * 3.1 + 7.0, 13.0));
    if (keep < 0.82) {
        return 0.0;
    }
    let jitter = (rnd - 0.5) * 0.64;
    let delta = vec2<f32>(f.x - jitter.x, (f.y - jitter.y) * 0.42);
    let d = length(delta);
    let twinkle = 0.45 + 0.55 * sin(t * 9.0 + rnd.x * TAU + rnd.y * 19.0);
    let r = 0.075 + 0.055 * rnd.y;
    let dot_m = 1.0 - smoothstep(r * 0.20, r, d);
    return dot_m * twinkle;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let asp = aspect();
    // Gentle monotonic toroidal drift upward and sideways so no pixel ever sits still.
    let drift = vec2<f32>(t * 0.024 / asp, t * 0.036);
    let uv0 = fract(state_uv(p) + drift);

    // Strong anisotropic upward-flowing turbulence warp for sinuous licking flame curtains.
    let w_pre = state_sample(uv0).y;
    let warp_n1 = periodic_fbm(uv0, vec2<f32>(max(6.0, round(asp * 11.0)), 5.0), vec2<f32>(0.0, -t * 2.8)) - 0.5;
    let warp_n2 = periodic_fbm(uv0, vec2<f32>(max(10.0, round(asp * 18.0)), 9.0), vec2<f32>(4.3, -t * 4.4)) - 0.5;
    let warp_amp = 0.036 * smoothstep(0.02, 0.32, w_pre);
    let uv = fract(uv0 + vec2<f32>(warp_n1 * warp_amp / asp, warp_n2 * warp_amp * 0.85));

    let s = state_sample(uv);
    let heat = clamp(s.x, 0.0, 1.45);
    let wisp = clamp(s.y, 0.0, 1.0);
    let cinder = clamp(s.z, 0.0, 1.0);
    let lip = clamp(s.w, 0.0, 1.0);

    // Sculpt crisp dark air folds between outer tongues and blazing ridged filaments inside cores.
    let carve_hi = periodic_fbm(uv, vec2<f32>(max(10.0, round(asp * 16.0)), 6.0), vec2<f32>(1.1, -t * 4.8));
    let ridged = periodic_ridged_fbm(uv, vec2<f32>(max(14.0, round(asp * 22.0)), 10.0), vec2<f32>(5.7, -t * 7.0));

    let carve_weight = 0.34 * (1.0 - smoothstep(0.28, 0.88, heat));
    let flame_val = heat * (1.00 + 0.42 * ridged) - carve_hi * carve_weight;
    let outer_edge = smoothstep(0.11, 0.25, flame_val);
    let body = smoothstep(0.22, 0.48, flame_val);
    let core = smoothstep(0.46, 0.82, flame_val);

    // Subtle deep crimson ember glow immediately hugging the carved flame tongues.
    let halo = smoothstep(0.08, 0.36, wisp - carve_hi * 0.24) * (1.0 - outer_edge) * 0.20;

    let temp = clamp(flame_val * (0.98 + 0.36 * ridged) + core * 0.22, 0.0, 1.24);
    let flame_col = fire_palette(temp, lip);
    let halo_col = mix(vec3<f32>(0.42, 0.02, 0.08), vec3<f32>(0.88, 0.10, 0.06), clamp(wisp * 1.4, 0.0, 1.0));

    var col = halo_col * halo + flame_col * (outer_edge * 0.42 + body * 0.32 + core * 0.28);

    // Sparse razor-sharp rising ember sparks trailing above the flames.
    let gate_lo = smoothstep(0.10, 0.42, cinder + wisp * 0.20);
    let gate_hi = smoothstep(0.14, 0.50, cinder + heat * 0.18);
    let sp_fine = spark_layer(uv, t, asp, 34.0, 10.5, 0.0) * gate_lo;
    let sp_med = spark_layer(uv, t, asp, 18.0, 7.2, 17.3) * gate_hi;
    let spark_col = vec3<f32>(1.00, 0.88, 0.48);
    let ember_tip = vec3<f32>(1.00, 0.46, 0.12);
    col = col + spark_col * (sp_fine * 1.15) + ember_tip * (sp_med * 0.95);

    // Soft highlight roll-off keeping incandescent cores bright without clipping care.max_white.
    col = col / (vec3<f32>(1.0) + col * 0.12);
    return clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
}
