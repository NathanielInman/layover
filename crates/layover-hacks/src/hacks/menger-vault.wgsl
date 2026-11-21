// Menger Vault: an endless vaulted Menger sponge curving through the dark,
// lit by drifting world-anchored bay lanterns and subtle rib tracers.
// After xscreensaver's Menger (Jamie Zawinski, 2001) and Sierpinski3D
// (Tim Robinson & Jamie Zawinski, 1999).

const BAY_STEP: f32 = 4.5;

fn path_xy(z: f32) -> vec2<f32> {
    return vec2<f32>(
        0.52 * sin(z * 0.13 + g.seed * TAU),
        0.34 * cos(z * 0.11 + g.seed * 3.7),
    );
}

fn vault_coords(p: vec3<f32>) -> vec3<f32> {
    let shift = p.xy - path_xy(p.z);
    let xy = rot2(p.z * 0.055 + sin(p.z * 0.04) * 0.25) * shift;
    return vec3<f32>(xy.x, xy.y, p.z);
}

fn sdf(p: vec3<f32>, t: f32) -> f32 {
    let q = vault_coords(p);
    // Main vaulted 3-axis shafts with 0.52 half-width clearway inside a 3.0 cell.
    var d = -sd_cross(op_rep(q, vec3<f32>(3.0)), 0.52);
    var s = 1.0;
    for (var i = 0; i < 3; i = i + 1) {
        s = s * 3.0;
        let r = op_rep(q * s, vec3<f32>(3.0));
        let carve = -sd_cross(r, 0.50) / s;
        d = max(d, carve);
    }
    let breath = 0.004 + 0.002 * sin(t * 0.35 + q.z * 0.5);
    return d - breath;
}

// World-anchored lantern drifting gently inside bay `bay`.
fn bay_lantern(bay: f32, t: f32) -> vec3<f32> {
    let lz = bay * BAY_STEP;
    let drift = vec2<f32>(
        0.22 * sin(t * 0.33 + bay * 2.1),
        0.18 * cos(t * 0.29 + bay * 1.7),
    );
    return vec3<f32>(path_xy(lz) + drift, lz);
}

fn bay_color(bay: f32) -> vec3<f32> {
    let f = 0.5 + 0.5 * sin(bay * 2.094 + g.seed * TAU);
    let frost = vec3<f32>(0.36, 0.78, 0.90);
    let amber = vec3<f32>(0.95, 0.64, 0.32);
    let plum = vec3<f32>(0.74, 0.44, 0.84);
    if (f < 0.5) {
        return mix(frost, amber, f * 2.0);
    }
    return mix(amber, plum, (f - 0.5) * 2.0);
}

// Soft volumetric glow of a bay lantern along ray (ro, rd), occluded at `hit_d`.
fn lantern_glow(ro: vec3<f32>, rd: vec3<f32>, lpos: vec3<f32>, hit_d: f32, lcol: vec3<f32>) -> vec3<f32> {
    let oc = lpos - ro;
    let proj = dot(oc, rd);
    if (proj <= 0.15 || proj >= hit_d) {
        return vec3<f32>(0.0);
    }
    let closest = ro + rd * proj;
    let dist = length(lpos - closest);
    let fade = exp(-proj * proj * 0.025) * smoothstep(0.15, 0.9, proj);
    let core = exp(-dist * dist * 160.0) * 0.85;
    let halo = exp(-dist * 5.5) * 0.28;
    return lcol * (core + halo) * fade;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let z = t * 0.52 + g.seed * 23.0;
    let sway = vec2<f32>(
        0.18 * sin(t * 0.23 + g.seed * 5.0),
        0.15 * cos(t * 0.19 + g.seed * 2.3),
    );
    let ro = vec3<f32>(path_xy(z) + sway, z);
    let look_z = z + 2.6;
    let look_off = vec2<f32>(
        0.22 * sin(t * 0.13 + 1.2),
        0.14 * cos(t * 0.11 + 0.4),
    );
    let look_at = vec3<f32>(path_xy(look_z) + look_off, look_z);
    let roll = 0.48 * sin(t * 0.095 + g.seed * TAU);
    let rd = camera_ray(p, ro, look_at, roll, 1.15);

    let bg = vec3<f32>(0.002, 0.004, 0.008);
    let max_d = 12.0;
    let h = rm_march(ro, rd, t, max_d, 56, 0.78);

    // Two adjacent world-anchored bay lanterns ahead of/around the camera: seamless lighting.
    let bay0 = floor(z / BAY_STEP) + 1.0;
    let bay1 = bay0 + 1.0;
    let lpos0 = bay_lantern(bay0, t);
    let lpos1 = bay_lantern(bay1, t);
    let lcol0 = bay_color(bay0);
    let lcol1 = bay_color(bay1);
    let p0 = 0.72 + 0.28 * sin(t * 0.65 + bay0 * 1.9);
    let p1 = 0.72 + 0.28 * sin(t * 0.65 + bay1 * 1.9);

    var col = bg;
    if (h.hit) {
        let hp = ro + rd * h.dist;
        let n = rm_normal(hp, t, max(0.0015, 0.0012 * h.dist));
        let ao = rm_ao(hp, n, t);

        // Primary light from bay0 (with soft shadow) + fill from bay1 (seamless across bays).
        let to0 = lpos0 - hp;
        let d0 = length(to0);
        let dir0 = to0 / max(d0, 1e-4);
        let att0 = p0 / (1.0 + d0 * d0 * 0.26);
        let sh0 = rm_shadow(hp + n * 0.014, dir0, t, 0.03, min(d0, 4.5), 6.5);
        let diff0 = max(dot(n, dir0), 0.0);
        let spec0 = pow(max(dot(n, normalize(dir0 - rd)), 0.0), 24.0) * 0.65;

        let to1 = lpos1 - hp;
        let d1 = length(to1);
        let dir1 = to1 / max(d1, 1e-4);
        let att1 = p1 / (1.0 + d1 * d1 * 0.28);
        let diff1 = max(dot(n, dir1), 0.0);
        let spec1 = pow(max(dot(n, normalize(dir1 - rd)), 0.0), 24.0) * 0.45;

        let rim = fresnel(n, -rd, 2.6);
        let cam_atten = 0.25 / (1.0 + h.dist * h.dist * 0.55);

        let q = vault_coords(hp);
        let rib1 = abs(op_rep(q * 3.0, vec3<f32>(3.0)));
        let rib2 = abs(op_rep(q * 9.0, vec3<f32>(3.0)));
        let edge_band = smoothstep(0.40, 0.53, max(min(rib1.x, rib1.y), min(rib1.y, rib1.z)));
        let fine_band = smoothstep(0.43, 0.55, max(min(rib2.x, rib2.y), min(rib2.y, rib2.z)));

        let stone = vec3<f32>(0.22, 0.34, 0.48);
        let base = mix(stone, mix(lcol0, lcol1, 0.35), edge_band * 0.45);
        let tracer = pow(0.5 + 0.5 * sin(q.z * 1.4 - t * 1.1 + rib1.x * 2.0), 3.0);

        let direct0 = (base * (diff0 * 1.55 + 0.06) + lcol0 * spec0) * sh0 * att0;
        let direct1 = (base * (diff1 * 1.15 + 0.04) + lcol1 * spec1) * att1 * 0.75;
        let rim_tint = mix(lcol0, lcol1, smoothstep(0.0, BAY_STEP, hp.z - lpos0.z));
        let rim_lit = rim_tint * rim * ao * (att0 * 0.85 + att1 * 0.55 + cam_atten);
        let edge_lit = rim_tint * fine_band * tracer * ao * (0.34 * att0 + 0.22 * att1 + 0.14 * cam_atten);

        col = (direct0 + direct1 + rim_lit + edge_lit) * (0.24 + 0.76 * ao);
        col = fog_exp(col, bg, h.dist, 0.036);
    }

    let occ_d = select(max_d, h.dist, h.hit);
    col = col + lantern_glow(ro, rd, lpos0, occ_d, lcol0) * p0;
    col = col + lantern_glow(ro, rd, lpos1, occ_d, lcol1) * p1;
    return col;
}
