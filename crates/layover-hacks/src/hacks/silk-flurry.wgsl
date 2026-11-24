// Silk Flurry: silky 3D plasma ribbons and luminous smoke tendrils streaming
// from orbiting sparks across the dark on Tier P compute particles and
// advected Tier S feedback textures.
// After xscreensaver's Flurry (Calum Robinson, 2002; Tobias Sargeant, 2003).
//
// Particle buffer layout (`particles[idx]`):
//   p.xyz = 3D position relative to cluster center (canvas heights)
//   p.w   = particle age in seconds within current ribbon cycle
//   v.xyz = 3D velocity relative to cluster center (canvas heights/sec)
//   v.w   = particle lifetime in seconds
//   c.rgb = birth base RGB color
//   c.w   = packed integer `((epoch % 16384u) * 512u + (birth_gen % 512u)) + 1u`
//           stored exact in f32 (0 = uninitialized)

const DRIFT_VX: f32 = 0.145;
const EPOCH_SECS: f32 = 30.0;
const W_REF: f32 = 0.0068;

struct ArchSpec {
    n_sparks: u32,
    pal_id: u32,
    life: f32,
    drag: f32,
    kick: f32,
    inherit: f32,
    pull: f32,
    swirl: f32,
    curl_amp: f32,
    spread: f32,
    buoy: f32,
    orbit_r: f32,
    speed: f32,
};

fn rotate_3d(v: vec3<f32>, yaw: f32, pitch: f32, roll: f32) -> vec3<f32> {
    let xz = rot2(yaw) * v.xz;
    let v1 = vec3<f32>(xz.x, v.y, xz.y);
    let yz = rot2(pitch) * v1.yz;
    let v2 = vec3<f32>(v1.x, yz.x, yz.y);
    let xy = rot2(roll) * v2.xy;
    return vec3<f32>(xy.x, xy.y, v2.z);
}

fn arch_spec(arch: u32, cluster_id: u32, gen: u32) -> ArchSpec {
    var s: ArchSpec;
    let pal_base = (gen * 3u + cluster_id * 2u + u32(g.seed * 17.0)) % 5u;
    if (arch == 0u) {
        // Classic Starfish: 5 sparks in a pulsing harmonic star dance.
        s = ArchSpec(5u, 0u, 1.95, 1.40, 0.24, 0.64, 0.44, 0.70, 0.24, 0.052, 0.015, 0.23, 1.32);
    } else if (arch == 1u) {
        // Water Current: 6 fluid sparks trailing long undulating ocean silk ribbons.
        s = ArchSpec(6u, 1u, 2.15, 1.08, 0.18, 0.84, 0.26, 0.36, 0.30, 0.058, 0.000, 0.26, 1.15);
    } else if (arch == 2u) {
        // Solar Flare: 7 brisk sparks with buoyant corona wisps.
        s = ArchSpec(7u, 2u, 1.75, 1.68, 0.28, 0.56, 0.34, 0.54, 0.26, 0.068, 0.048, 0.21, 1.46);
    } else if (arch == 3u) {
        // Ribbon Braid: 6 counter-rotating sparks weaving crisp braided figure-8 cords.
        s = ArchSpec(6u, 3u, 2.05, 1.25, 0.19, 0.78, 0.52, 0.44, 0.16, 0.036, 0.000, 0.24, 1.22);
    } else {
        // Cyclone Lotus: 7 vortex sparks twisting plumes into spiral 3D petals.
        s = ArchSpec(7u, 4u, 1.90, 1.35, 0.22, 0.68, 0.38, 1.12, 0.20, 0.046, 0.010, 0.25, 1.35);
    }
    s.pal_id = (s.pal_id + pal_base) % 5u;
    return s;
}

// Five curated Flurry color palettes with balanced R/G/B coverage across the wheel.
fn flurry_palette(pal: u32, spark_id: u32, n_sparks: u32, t: f32) -> vec3<f32> {
    let u = f32(spark_id) / max(f32(n_sparks), 1.0);
    let p = pal % 5u;

    if (p == 0u) {
        // Classic Flurry Spectrum: smooth slow rainbow sweep across sparks.
        let ph = u * TAU + t * 0.16;
        return vec3<f32>(
            0.55 + 0.45 * cos(ph),
            0.55 + 0.45 * cos(ph - 2.0943951),
            0.55 + 0.45 * cos(ph - 4.1887902),
        );
    }
    if (p == 1u) {
        // Deep Water: sapphire, cerulean, aquamarine, seafoam and indigo.
        let ph = u * PI * 1.4 + t * 0.12;
        return vec3<f32>(
            0.14 + 0.22 * (0.5 + 0.5 * sin(ph + 1.2)),
            0.50 + 0.46 * (0.5 + 0.5 * sin(ph)),
            0.76 + 0.24 * (0.5 + 0.5 * cos(ph * 0.8)),
        );
    }
    if (p == 2u) {
        // Hearth Fire: ruby, vermilion, amber gold and warm rose.
        let ph = u * PI * 1.3 + t * 0.14;
        return vec3<f32>(
            0.88 + 0.12 * cos(ph),
            0.24 + 0.58 * (0.5 + 0.5 * sin(ph)),
            0.12 + 0.28 * (0.5 + 0.5 * cos(ph * 1.5 + 0.8)),
        );
    }
    if (p == 3u) {
        // Aurora Prism: emerald jade, glacial cyan, violet and rose magenta.
        let k = spark_id % 4u;
        if (k == 0u) {
            return vec3<f32>(0.18, 0.96, 0.68);
        }
        if (k == 1u) {
            return vec3<f32>(0.20, 0.74, 1.00);
        }
        if (k == 2u) {
            return vec3<f32>(0.68, 0.34, 1.00);
        }
        return vec3<f32>(1.00, 0.32, 0.72);
    }
    // Classic Flurry RGB Triads: crisp jewel coral, spring teal and cobalt violet.
    let k = spark_id % 3u;
    if (k == 0u) {
        return vec3<f32>(1.00, 0.26, 0.36);
    }
    if (k == 1u) {
        return vec3<f32>(0.16, 0.94, 0.52);
    }
    return vec3<f32>(0.24, 0.52, 1.00);
}

fn cluster_center(cluster_id: u32, n_clusters: u32, gen: u32, t: f32) -> vec2<f32> {
    let a = aspect();
    let fc = f32(cluster_id);
    let fg = f32(gen);
    let jx = (hash11(fc * 19.7 + fg * 31.3 + g.seed * 59.0) - 0.5) * 0.30;
    let x0 = fract((fc + 0.5 + jx) / f32(n_clusters) + g.seed * 0.41) * a;
    let y_base = 0.28 + 0.44 * fract(0.19 + fc * 0.43 + fg * 0.618034 + g.seed * 0.53);
    let y_sway = 0.055 * sin(t * 0.31 + fc * 2.3 + fg * 1.1);
    return vec2<f32>(
        fract((x0 + DRIFT_VX * t) / a) * a,
        clamp(y_base + y_sway, 0.24, 0.76),
    );
}

fn cluster_angles(cluster_id: u32, gen: u32, phase: f32) -> vec3<f32> {
    let fc = f32(cluster_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fc * 23.1 + fg * 41.7, g.seed * 71.0 + 3.7));
    let yaw = 0.48 * sin(phase * 0.14 + h.x * TAU) + h.y * 0.6;
    let pitch = 0.44 * cos(phase * 0.11 + h.y * TAU) + (h.x - 0.5) * 0.5;
    let roll = h.x * TAU + phase * 0.19 * select(-1.0, 1.0, (cluster_id + gen) % 2u == 0u);
    return vec3<f32>(yaw, pitch, roll);
}

// Moving 3D anchor ("star" in flurry.c) so cluster centers never dwell over one spot.
fn eval_star_pos(arch: u32, cluster_id: u32, gen: u32, phase: f32) -> vec3<f32> {
    let fc = f32(cluster_id);
    let fg = f32(gen);
    let ph = hash11(fc * 13.1 + fg * 29.3 + g.seed * 43.0) * TAU;
    let w = phase * 0.85 + ph;
    let amp = select(0.070, 0.095, arch == 1u || arch == 2u);
    return vec3<f32>(
        amp * cos(w * 0.91 + 0.4),
        amp * 0.80 * sin(w * 1.17 + 1.1),
        amp * 0.70 * sin(w * 0.73 - 0.5),
    );
}

fn eval_spark_pos(
    spec: ArchSpec,
    arch: u32,
    spark_id: u32,
    cluster_id: u32,
    gen: u32,
    phase: f32,
) -> vec3<f32> {
    let fi = f32(spark_id);
    let fn_s = max(f32(spec.n_sparks), 1.0);
    let base_a = fi * (TAU / fn_s);
    let ang_off = hash11(fi * 17.3 + f32(cluster_id) * 11.1 + f32(gen) * 7.9) * 0.8;
    let t = phase * spec.speed;
    let star = eval_star_pos(arch, cluster_id, gen, phase);
    var local = vec3<f32>(0.0);

    if (arch == 0u) {
        // Starfish: pulsing 5-lobe flower orbital dance.
        let rot_w = t * 1.15 + base_a;
        let pulse = 0.68 + 0.36 * sin(t * 2.15 + fi * 1.45 + ang_off);
        let r = spec.orbit_r * pulse;
        local = vec3<f32>(
            r * cos(rot_w),
            r * sin(rot_w) * (0.88 + 0.16 * cos(t * 1.3 + fi)),
            spec.orbit_r * 0.48 * sin(t * 1.75 + fi * 2.1 + ang_off),
        );
    } else if (arch == 1u) {
        // Water Current: sweeping eccentric figure-8 currents.
        let w = t * 1.05 + base_a;
        let rx = spec.orbit_r * (1.08 + 0.25 * cos(t * 0.8 + fi));
        let ry = spec.orbit_r * (0.82 + 0.22 * sin(t * 1.1 + fi));
        local = vec3<f32>(
            rx * cos(w) + 0.04 * sin(w * 2.0 + fi),
            ry * sin(w * 1.5 + ang_off),
            spec.orbit_r * 0.52 * cos(w * 0.85 - fi * 1.2),
        );
    } else if (arch == 2u) {
        // Solar Flare: alternating inner/outer orbital shells with rapid nutation.
        let ring = select(0.72, 1.12, (spark_id & 1u) == 0u);
        let dir = select(-1.0, 1.0, (spark_id & 1u) == 0u);
        let w = dir * t * 1.35 + base_a;
        let r = spec.orbit_r * ring * (0.85 + 0.20 * sin(t * 2.6 + fi * 1.9));
        local = vec3<f32>(
            r * cos(w),
            r * sin(w),
            spec.orbit_r * 0.46 * sin(t * 2.2 + base_a * 2.0),
        );
    } else if (arch == 3u) {
        // Ribbon Braid: counter-rotating tilted trefoil rings that weave clean helixes.
        let dir = select(-1.0, 1.0, (spark_id & 1u) == 0u);
        let w = dir * t * 1.10 + base_a;
        let r = spec.orbit_r * (0.86 + 0.22 * cos(w * 2.0 + fi));
        let tilt = select(-0.42, 0.42, (spark_id & 1u) == 0u);
        let raw = vec3<f32>(r * cos(w), r * sin(w), 0.085 * sin(w * 3.0 + fi));
        local = rotate_3d(raw, tilt, -tilt * 0.7, 0.0);
    } else {
        // Cyclone Lotus: brisk rosette orbit tilted into 3D bowl.
        let w = t * 1.25 + base_a;
        let r = spec.orbit_r * (0.64 + 0.40 * cos(w * 1.4 + ang_off));
        local = vec3<f32>(
            r * cos(w),
            r * sin(w),
            spec.orbit_r * 0.50 * cos(w * 2.0 + fi * 0.9),
        );
    }

    let ang = cluster_angles(cluster_id, gen, phase);
    return star + rotate_3d(local, ang.x, ang.y, ang.z);
}

fn spark_state(
    spec: ArchSpec,
    arch: u32,
    spark_id: u32,
    cluster_id: u32,
    gen: u32,
    phase: f32,
) -> array<vec3<f32>, 3> {
    let eps = 0.012;
    let star = eval_star_pos(arch, cluster_id, gen, phase);
    let p_cur = eval_spark_pos(spec, arch, spark_id, cluster_id, gen, phase);
    let p_m = eval_spark_pos(spec, arch, spark_id, cluster_id, gen, phase - eps);
    let p_p = eval_spark_pos(spec, arch, spark_id, cluster_id, gen, phase + eps);
    let vel = (p_p - p_m) * (0.5 / eps);
    return array<vec3<f32>, 3>(p_cur, vel, star);
}

// Smooth divergence-inspired 3D curl field so adjacent particles form silky waves.
fn smoke_curl(pos: vec3<f32>, t: f32, amp: f32) -> vec3<f32> {
    let q = pos * 9.0 + vec3<f32>(t * 0.52, -t * 0.40, t * 0.35);
    return vec3<f32>(
        sin(q.y * 1.3 + cos(q.z * 1.1)),
        cos(q.z * 1.2 - sin(q.x * 1.4)),
        sin(q.x * 1.1 + cos(q.y * 1.3)),
    ) * amp;
}

fn integrate_smoke(
    pos: vec3<f32>,
    vel: vec3<f32>,
    star_pos: vec3<f32>,
    spec: ArchSpec,
    swirl_sign: f32,
    t_mid: f32,
    dt: f32,
) -> array<vec3<f32>, 2> {
    let to_star = star_pos - pos;
    let d2 = dot(to_star, to_star) + 0.032;
    let grav_acc = to_star * (spec.pull / (d2 * 8.0 + 1.0));
    let curl_acc = smoke_curl(pos, t_mid, spec.curl_amp);
    let swirl_acc = vec3<f32>(-pos.y, pos.x, 0.25 * (pos.x - pos.y)) * (spec.swirl * swirl_sign);
    let buoy_acc = vec3<f32>(0.0, spec.buoy, 0.0);
    let acc = grav_acc + curl_acc + swirl_acc + buoy_acc;

    let e = exp(-spec.drag * dt);
    let k_inv = 1.0 / max(spec.drag, 0.05);
    let v_term = acc * k_inv;
    let next_pos = pos + v_term * dt + (vel - v_term) * ((1.0 - e) * k_inv);
    let next_vel = v_term + (vel - v_term) * e;
    return array<vec3<f32>, 2>(next_pos, next_vel);
}

fn spawn_smoke(
    spec: ArchSpec,
    arch: u32,
    spark_id: u32,
    strand_id: u32,
    n_strands: u32,
    cluster_id: u32,
    gen: u32,
    t_birth: f32,
) -> array<vec3<f32>, 3> {
    let ss = spark_state(spec, arch, spark_id, cluster_id, gen, t_birth);
    let s_pos = ss[0];
    let s_vel = ss[1];
    let star = ss[2];

    let rel = s_pos - star;
    let rad_dir = normalize(rel + vec3<f32>(0.001, 0.002, 0.001));
    let tang = normalize(cross(rad_dir, vec3<f32>(0.0, 0.0, 1.0)) + vec3<f32>(0.001, 0.002, 0.0));
    let binorm = normalize(cross(rad_dir, tang));

    // Coherent strand phase varying smoothly with t_birth (zero random rank-to-rank bristles).
    let fs = f32(strand_id);
    let strand_u = fs / max(f32(n_strands), 1.0);
    let strand_a = strand_u * TAU
        + 0.45 * sin(t_birth * 1.15 + fs * 1.3 + f32(spark_id))
        + f32(spark_id) * 0.77;
    let strand_dir = tang * cos(strand_a) + binorm * sin(strand_a);

    let wave_x = sin(t_birth * 1.85 + fs * 1.7 + f32(spark_id) * 2.3 + f32(cluster_id));
    let wave_y = cos(t_birth * 1.45 - fs * 1.1 + f32(spark_id) * 1.9);

    let p0 = s_pos;
    let v0 = s_vel * spec.inherit
        + rad_dir * (spec.kick * (0.92 + 0.14 * wave_x))
        + strand_dir * (spec.spread * (0.78 + 0.32 * wave_y));
    let col = flurry_palette(spec.pal_id, spark_id, spec.n_sparks, t_birth);
    return array<vec3<f32>, 3>(p0, v0, col);
}

fn project_smoke(cluster_cm: vec2<f32>, l: vec3<f32>) -> vec3<f32> {
    let persp = 1.0 / (1.0 + clamp(l.z, -0.55, 1.40) * 0.42);
    return vec3<f32>(cluster_cm + l.xy * persp, l.z);
}

fn pack_birth(epoch: u32, birth_gen: u32) -> f32 {
    return f32(((epoch % 16384u) * 512u + (birth_gen % 512u)) + 1u);
}

fn splat_smoke_piece(
    cluster_cm: vec2<f32>,
    p_prev3: vec3<f32>,
    p_cur3: vec3<f32>,
    col: vec3<f32>,
    age: f32,
    life: f32,
    env: f32,
    norm_count: f32,
    sub_scale: f32,
    draw_disc: bool,
    allow_seg: bool,
) {
    let u = clamp(age / max(life, 0.1), 0.0, 1.0);
    if (u >= 1.0 || env <= 0.003) {
        return;
    }

    let pr0 = project_smoke(cluster_cm, p_prev3);
    let pr1 = project_smoke(cluster_cm, p_cur3);
    let y_clip = smoothstep(0.02, 0.08, pr1.y) * (1.0 - smoothstep(0.92, 0.98, pr1.y));
    let depth_fade = clamp(0.90 - pr1.z * 0.25, 0.38, 1.15);
    let r_fade = 1.0 - smoothstep(0.46, 0.76, length(p_cur3));

    // Classic Flurry ribbon envelope: smooth entry into the spark, lush silky body, graceful smoke fade-out.
    let ribbon_env = smoothstep(0.0, 0.09, u) * pow(1.0 - smoothstep(0.24, 1.0, u), 1.35);
    let w_eff = ribbon_env * env * y_clip * depth_fade * r_fade * norm_count;
    if (w_eff <= 0.004) {
        return;
    }

    // Incandescent highlight near the spark tip, pure saturated jewel color along the billowing tail.
    let core_tint = pow(1.0 - u, 2.8) * 0.44;
    let tint_col = mix(col, vec3<f32>(1.0, 0.98, 0.95), core_tint);

    let h = f32(splat_dims().y);
    let dt_fade = max(1.0 - g.fade, 0.008);
    // Unified h^2 area scaling keeps total canvas luminance equal across 72p wear tests and 540p live.
    let unit_e = (W_REF * h) * (W_REF * h) * dt_fade * w_eff;

    if (h < 180.0) {
        // Low-resolution wear grid (`256x72`): splat continuous velocity segments across substeps.
        let seg_e = unit_e * 1.55 * sub_scale;
        if (allow_seg && length(pr1.xy - pr0.xy) > 1e-5 && length(pr1.xy - pr0.xy) <= 0.25) {
            splat_segment(pr0.xy, pr1.xy, tint_col * seg_e, seg_e * (0.28 + 0.60 * core_tint), true);
        } else if (draw_disc) {
            splat_point_wrap(pr1.xy, tint_col * seg_e, seg_e * (0.28 + 0.60 * core_tint));
        }
        return;
    }

    if (draw_disc) {
        let radius = mix(0.0070, 0.0114, smoothstep(0.0, 0.80, u));
        let disc_e = unit_e * 1.55;
        let step_d = length(pr1.xy - pr0.xy);
        if (allow_seg && step_d > 0.002 && step_d <= 0.20) {
            let n_pts = clamp(i32(ceil(step_d * h / 1.8)), 2, 6);
            let inv_n = 1.0 / f32(n_pts);
            let rgb_pt = tint_col * (disc_e * inv_n);
            let a_pt = disc_e * (0.28 + 0.60 * core_tint) * inv_n;
            for (var k = 0; k < n_pts; k = k + 1) {
                let p_at = mix(pr0.xy, pr1.xy, (f32(k) + 0.5) * inv_n);
                splat_disc(p_at, radius, rgb_pt, a_pt, true);
            }
        } else {
            splat_disc(pr1.xy, radius, tint_col * disc_e, disc_e * (0.28 + 0.60 * core_tint), true);
        }
    }
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let n_clusters = select(3u, 2u, a < 2.4);
    let cluster_id = idx % n_clusters;
    let local_id = idx / n_clusters;
    let local_count = max(particle_count() / n_clusters, 1u);
    let norm_count = 4096.0 / f32(local_count);

    let fc = f32(cluster_id);
    let cluster_off = (fc / f32(n_clusters) + 0.13 * hash11(fc * 19.3 + g.seed * 41.0)) * EPOCH_SECS;
    let cycle_t = t + cluster_off;
    let gen = u32(max(floor(cycle_t / EPOCH_SECS), 0.0));
    let phase = cycle_t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.08, u_epoch) * (1.0 - smoothstep(0.90, 1.0, u_epoch));

    let arch = (gen + cluster_id * 2u + u32(g.seed * 13.0)) % 5u;
    let spec = arch_spec(arch, cluster_id, gen);
    let cluster_cm = cluster_center(cluster_id, n_clusters, gen, t);
    let swirl_sign = select(-1.0, 1.0, (cluster_id + gen) % 2u == 0u);

    // Reserve first `spec.n_sparks` slots per cluster as luminous orbiting spark heads.
    if (local_id < spec.n_sparks) {
        let ss = spark_state(spec, arch, local_id, cluster_id, gen, phase);
        let pr1 = project_smoke(cluster_cm, ss[0]);
        let y_clip = smoothstep(0.02, 0.08, pr1.y) * (1.0 - smoothstep(0.92, 0.98, pr1.y));
        let depth_fade = clamp(0.92 - pr1.z * 0.25, 0.42, 1.15);
        let col = flurry_palette(spec.pal_id, local_id, spec.n_sparks, phase);
        let spark_col = mix(col, vec3<f32>(1.0, 0.98, 0.94), 0.42);

        let h = f32(splat_dims().y);
        let dt_fade = max(1.0 - g.fade, 0.008);
        let rad = 0.0054;
        let head_e = (rad * h) * (rad * h) * dt_fade * 2.10 * env * y_clip * depth_fade * norm_count;
        splat_disc(pr1.xy, rad, spark_col * head_e, head_e * 2.2, true);
        particles[idx].c.w = pack_birth(gen, 0u);
        return;
    }

    let trail_id = local_id - spec.n_sparks;
    let spark_id = trail_id % spec.n_sparks;
    let slot = trail_id / spec.n_sparks;
    let slot_count = max((local_count - spec.n_sparks) / spec.n_sparks, 1u);
    let n_strands = 2u;
    let strand_id = slot % n_strands;
    let rank = slot / n_strands;
    let n_ranks = max(slot_count / n_strands, 1u);

    let life = spec.life * mix(0.90, 1.10, hash11(f32(strand_id) * 7.3 + f32(spark_id) * 19.1));
    let rank_frac = f32(rank) / f32(n_ranks);
    let strand_stagger = (f32(strand_id) / f32(n_strands)) / f32(n_ranks);
    let slot_phase = fract(rank_frac + strand_stagger + f32(spark_id) * 0.173) * life;

    let u_life = (phase + slot_phase) / life;
    let birth_gen = u32(max(floor(u_life), 0.0));
    let age_now = (u_life - f32(birth_gen)) * life;
    let packed_now = pack_birth(gen, birth_gen);

    var st = particles[idx];
    let uninit = g.frame < 0.5
        || st.c.w <= 0.5
        || abs(st.c.w - packed_now) > 0.5
        || !all(st.p.xyz == st.p.xyz);

    if (uninit) {
        let t_birth = phase - age_now;
        let sp = spawn_smoke(spec, arch, spark_id, strand_id, n_strands, cluster_id, gen, t_birth);
        var pos = sp[0];
        var vel = sp[1];
        let col = sp[2];

        if (age_now > 0.002) {
            let n_warm = clamp(i32(ceil(age_now / 0.14)), 1, 16);
            let w_dt = age_now / f32(n_warm);
            for (var s = 0; s < n_warm; s = s + 1) {
                let t_mid = t_birth + (f32(s) + 0.5) * w_dt;
                let star_mid = eval_star_pos(arch, cluster_id, gen, t_mid);
                let res = integrate_smoke(pos, vel, star_mid, spec, swirl_sign, t_mid, w_dt);
                pos = res[0];
                vel = res[1];
            }
        }

        splat_smoke_piece(
            cluster_cm,
            pos,
            pos,
            col,
            age_now,
            life,
            env,
            norm_count,
            1.0,
            true,
            false,
        );
        particles[idx].p = vec4<f32>(pos, age_now);
        particles[idx].v = vec4<f32>(vel, life);
        particles[idx].c = vec4<f32>(col, packed_now);
        return;
    }

    var pos = st.p.xyz;
    var vel = st.v.xyz;
    var age = st.p.w;
    var col = st.c.rgb;

    let n_sub = clamp(i32(ceil(g.dt / 0.04)), 1, 7);
    let h_dt = g.dt / f32(n_sub);
    let sub_scale = 1.0 / f32(n_sub);

    for (var s = 0; s < n_sub; s = s + 1) {
        let t_sub_end = phase - g.dt + f32(s + 1) * h_dt;
        let next_age = age + h_dt;
        if (next_age >= life) {
            let wrapped_age = next_age - life;
            let t_birth = t_sub_end - wrapped_age;
            let sp = spawn_smoke(
                spec,
                arch,
                spark_id,
                strand_id,
                n_strands,
                cluster_id,
                gen,
                t_birth,
            );
            pos = sp[0];
            vel = sp[1];
            col = sp[2];
            if (wrapped_age > 0.001) {
                let star_mid = eval_star_pos(arch, cluster_id, gen, t_birth + 0.5 * wrapped_age);
                let res = integrate_smoke(
                    pos,
                    vel,
                    star_mid,
                    spec,
                    swirl_sign,
                    t_birth + 0.5 * wrapped_age,
                    wrapped_age,
                );
                pos = res[0];
                vel = res[1];
            }
            age = wrapped_age;
            splat_smoke_piece(
                cluster_cm,
                sp[0],
                pos,
                col,
                age,
                life,
                env,
                norm_count,
                sub_scale,
                s + 1 == n_sub,
                wrapped_age > 0.002,
            );
        } else {
            let p_prev = pos;
            let t_mid = t_sub_end - 0.5 * h_dt;
            let star_mid = eval_star_pos(arch, cluster_id, gen, t_mid);
            let res = integrate_smoke(pos, vel, star_mid, spec, swirl_sign, t_mid, h_dt);
            pos = res[0];
            vel = res[1];
            age = next_age;
            splat_smoke_piece(
                cluster_cm,
                p_prev,
                pos,
                col,
                age,
                life,
                env,
                norm_count,
                sub_scale,
                s + 1 == n_sub,
                true,
            );
        }
    }

    particles[idx].p = vec4<f32>(pos, age);
    particles[idx].v = vec4<f32>(vel, life);
    particles[idx].c = vec4<f32>(col, packed_now);
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
        let diff = clamp(g.dt * 12.0, 0.0, 0.38);
        prev = mix(prev, blur, diff);
    }
    let core_fade = exp(-g.dt * 10.0);
    return vec4<f32>(prev.rgb * g.fade, prev.a * core_fade) + splat;
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    let s = state_sample(uv);
    let d = state_texel();

    // Tight optical silk halo around luminous ribbon cores.
    let h_card = state_sample(uv + vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv - vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.4))
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.4));
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.5, d.y * 2.5))
        + state_sample(uv + vec2<f32>(-d.x * 2.5, d.y * 2.5))
        + state_sample(uv + vec2<f32>(d.x * 2.5, -d.y * 2.5))
        + state_sample(uv + vec2<f32>(-d.x * 2.5, -d.y * 2.5));
    let halo = (h_card + h_diag) * 0.125;

    // Soft smoke veil around bright billowing ribbons.
    let veil = (
        state_sample(uv + vec2<f32>(d.x * 4.2, d.y * 4.2))
        + state_sample(uv + vec2<f32>(-d.x * 4.2, d.y * 4.2))
        + state_sample(uv + vec2<f32>(d.x * 4.2, -d.y * 4.2))
        + state_sample(uv + vec2<f32>(-d.x * 4.2, -d.y * 4.2))
    ) * 0.25;

    let raw_rgb = max(s.rgb + halo.rgb * 0.34 + veil.rgb * 0.18, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4 && s.a <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // Chromaticity-preserving exponential tone mapping keeps silk hues rich across overlaps.
    let mapped_lum = 1.0 - exp(-peak_c * 1.50);
    var out_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    let hot = clamp(s.a * 0.56 + halo.a * 0.14, 0.0, 1.5);
    let incand = smoothstep(0.24, 1.05, hot) * 0.44 * smoothstep(0.04, 0.32, mapped_lum);
    out_col = mix(out_col, vec3<f32>(1.0, 0.98, 0.94), incand);
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}
