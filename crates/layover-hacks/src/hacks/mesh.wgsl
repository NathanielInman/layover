// Shared depth-buffered 3D mesh helpers for Tier M hacks (`mesh: Some(...)`).
//
// A Tier M hack defines three hooks in addition to `fn hack(p: vec2<f32>, t: f32) -> vec3<f32>`:
//
//   fn mesh_camera(t: f32) -> MeshCamera
//     Provides view/projection matrices, camera eye and three-point lighting for the frame.
//
//   fn mesh_instance(draw: u32, inst: u32, t: f32) -> MeshInstance
//     Provides the model transform and material properties for draw `draw`, instance `inst`.
//
// Each mesh pass clears the Depth32Float buffer to 1.0 and preserves the background painted by
// `hack(p, t)` so procedural starfields, nebulae or gradients compose seamlessly behind 3D geometry.

struct MeshVertexIn {
    @location(0) pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct MeshCamera {
    eye: vec3<f32>,
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
    light_dir: vec3<f32>,
    light_col: vec3<f32>,
    fill_dir: vec3<f32>,
    fill_col: vec3<f32>,
    ambient: vec3<f32>,
    fog_density: f32,
};

struct MeshInstance {
    model: mat4x4<f32>,
    color: vec3<f32>,
    emissive: vec3<f32>,
    roughness: f32,
    metallic: f32,
    rim: f32,
    visible: f32,
};

struct MeshVsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) world_normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) @interpolate(flat) color_rough: vec4<f32>,
    @location(4) @interpolate(flat) emissive_metal: vec4<f32>,
    @location(5) @interpolate(flat) rim_pad: vec2<f32>,
};

fn mesh_draw_index() -> u32 {
    return u32(g.mesh_draw + 0.5);
}

fn mesh_instance_count() -> u32 {
    return u32(g.mesh_count + 0.5);
}

fn mesh_look_at(eye: vec3<f32>, look_at: vec3<f32>, up: vec3<f32>) -> mat4x4<f32> {
    let to_t = look_at - eye;
    let t2 = dot(to_t, to_t);
    let f = select(vec3<f32>(0.0, 0.0, -1.0), to_t * inverseSqrt(t2), t2 > 1e-10);
    let u_len2 = dot(up, up);
    var up_n = select(vec3<f32>(0.0, 1.0, 0.0), up * inverseSqrt(u_len2), u_len2 > 1e-10);
    if (abs(dot(f, up_n)) > 0.995) {
        up_n = vec3<f32>(0.0, 0.0, 1.0);
        if (abs(dot(f, up_n)) > 0.995) {
            up_n = vec3<f32>(1.0, 0.0, 0.0);
        }
    }
    let s = normalize(cross(f, up_n));
    let u = cross(s, f);
    return mat4x4<f32>(
        vec4<f32>(s.x, u.x, -f.x, 0.0),
        vec4<f32>(s.y, u.y, -f.y, 0.0),
        vec4<f32>(s.z, u.z, -f.z, 0.0),
        vec4<f32>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1.0),
    );
}

fn mesh_perspective(fov_y: f32, near: f32, far: f32) -> mat4x4<f32> {
    let f = 1.0 / tan(clamp(fov_y, 0.05, 3.0) * 0.5);
    let a = max(aspect(), 1e-4);
    let n = max(near, 1e-4);
    let fa = max(far, n + 1e-3);
    let inv = 1.0 / (n - fa);
    return mat4x4<f32>(
        vec4<f32>(f / a, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, f, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, fa * inv, -1.0),
        vec4<f32>(0.0, 0.0, fa * n * inv, 0.0),
    );
}

fn mesh_ortho(half_height: f32, near: f32, far: f32) -> mat4x4<f32> {
    let hh = max(half_height, 1e-4);
    let a = max(aspect(), 1e-4);
    let fa = max(far, near + 1e-3);
    let inv = 1.0 / (near - fa);
    return mat4x4<f32>(
        vec4<f32>(1.0 / (hh * a), 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0 / hh, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, inv, 0.0),
        vec4<f32>(0.0, 0.0, near * inv, 1.0),
    );
}

fn mesh_camera_persp(eye: vec3<f32>, look_at: vec3<f32>, fov_y: f32, near: f32, far: f32) -> MeshCamera {
    return MeshCamera(
        eye,
        mesh_look_at(eye, look_at, vec3<f32>(0.0, 1.0, 0.0)),
        mesh_perspective(fov_y, near, far),
        normalize(vec3<f32>(0.55, 0.80, 0.45)),
        vec3<f32>(0.95, 0.96, 1.00),
        normalize(vec3<f32>(-0.65, -0.25, -0.70)),
        vec3<f32>(0.24, 0.30, 0.42),
        vec3<f32>(0.05, 0.06, 0.08),
        0.0,
    );
}

fn mesh_camera_ortho(
    eye: vec3<f32>,
    look_at: vec3<f32>,
    half_height: f32,
    near: f32,
    far: f32,
) -> MeshCamera {
    return MeshCamera(
        eye,
        mesh_look_at(eye, look_at, vec3<f32>(0.0, 1.0, 0.0)),
        mesh_ortho(half_height, near, far),
        normalize(vec3<f32>(0.55, 0.80, 0.45)),
        vec3<f32>(0.95, 0.96, 1.00),
        normalize(vec3<f32>(-0.65, -0.25, -0.70)),
        vec3<f32>(0.24, 0.30, 0.42),
        vec3<f32>(0.05, 0.06, 0.08),
        0.0,
    );
}

fn mesh_translate(p: vec3<f32>) -> mat4x4<f32> {
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(p, 1.0),
    );
}

fn mesh_scale(s: vec3<f32>) -> mat4x4<f32> {
    return mat4x4<f32>(
        vec4<f32>(s.x, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, s.y, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, s.z, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
    );
}

fn mesh_rot_x(a: f32) -> mat4x4<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, c, s, 0.0),
        vec4<f32>(0.0, -s, c, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
    );
}

fn mesh_rot_y(a: f32) -> mat4x4<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat4x4<f32>(
        vec4<f32>(c, 0.0, -s, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(s, 0.0, c, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
    );
}

fn mesh_rot_z(a: f32) -> mat4x4<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat4x4<f32>(
        vec4<f32>(c, s, 0.0, 0.0),
        vec4<f32>(-s, c, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
    );
}

fn mesh_rot_axis(axis: vec3<f32>, angle: f32) -> mat4x4<f32> {
    let l2 = dot(axis, axis);
    let n = select(vec3<f32>(0.0, 1.0, 0.0), axis * inverseSqrt(l2), l2 > 1e-10);
    let c = cos(angle);
    let s = sin(angle);
    let oc = 1.0 - c;
    return mat4x4<f32>(
        vec4<f32>(n.x * n.x * oc + c, n.x * n.y * oc + n.z * s, n.x * n.z * oc - n.y * s, 0.0),
        vec4<f32>(n.x * n.y * oc - n.z * s, n.y * n.y * oc + c, n.y * n.z * oc + n.x * s, 0.0),
        vec4<f32>(n.x * n.z * oc + n.y * s, n.y * n.z * oc - n.x * s, n.z * n.z * oc + c, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
    );
}

fn mesh_trs(pos: vec3<f32>, euler_xyz: vec3<f32>, scale: vec3<f32>) -> mat4x4<f32> {
    return mesh_translate(pos) * mesh_rot_z(euler_xyz.z) * mesh_rot_y(euler_xyz.y) * mesh_rot_x(euler_xyz.x) * mesh_scale(scale);
}

// Orient a unit Y-aligned primitive (`Cylinder`, `Cone`, `HexPrism`) from `a` to `b`.
fn mesh_from_to(a: vec3<f32>, b: vec3<f32>, radius: f32) -> mat4x4<f32> {
    let d = b - a;
    let len = length(d);
    if (len < 1e-5) {
        return mesh_scale(vec3<f32>(0.0));
    }
    let y = d / len;
    let ref_v = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, 1.0), abs(y.x) > 0.9);
    let z = normalize(cross(ref_v, y));
    let x = cross(y, z);
    let w = radius * 2.0;
    let mid = 0.5 * (a + b);
    return mat4x4<f32>(
        vec4<f32>(x * w, 0.0),
        vec4<f32>(y * len, 0.0),
        vec4<f32>(z * w, 0.0),
        vec4<f32>(mid, 1.0),
    );
}

fn mesh_instance_none() -> MeshInstance {
    return MeshInstance(
        mat4x4<f32>(
            vec4<f32>(1.0, 0.0, 0.0, 0.0),
            vec4<f32>(0.0, 1.0, 0.0, 0.0),
            vec4<f32>(0.0, 0.0, 1.0, 0.0),
            vec4<f32>(0.0, 0.0, 0.0, 1.0),
        ),
        vec3<f32>(0.0),
        vec3<f32>(0.0),
        0.35,
        0.25,
        0.45,
        0.0,
    );
}

fn mesh_instance_mat(model: mat4x4<f32>, color: vec3<f32>) -> MeshInstance {
    return MeshInstance(
        model,
        color,
        vec3<f32>(0.0),
        0.35,
        0.25,
        0.45,
        1.0,
    );
}

fn mesh_instance_trs(pos: vec3<f32>, euler_xyz: vec3<f32>, scale: vec3<f32>, color: vec3<f32>) -> MeshInstance {
    return mesh_instance_mat(mesh_trs(pos, euler_xyz, scale), color);
}

fn mesh_material(
    inst: MeshInstance,
    roughness: f32,
    metallic: f32,
    rim: f32,
    emissive: vec3<f32>,
) -> MeshInstance {
    var out = inst;
    out.roughness = roughness;
    out.metallic = metallic;
    out.rim = rim;
    out.emissive = emissive;
    return out;
}

fn mesh_is_finite_vec4(v: vec4<f32>) -> bool {
    return all(v == v) && all(abs(v) < vec4<f32>(1e6));
}

fn mesh_vertex(v: MeshVertexIn, cam: MeshCamera, inst: MeshInstance) -> MeshVsOut {
    var out: MeshVsOut;
    out.world_pos = vec3<f32>(0.0);
    out.world_normal = vec3<f32>(0.0, 1.0, 0.0);
    out.uv = v.uv;
    out.color_rough = vec4<f32>(inst.color, inst.roughness);
    out.emissive_metal = vec4<f32>(inst.emissive, inst.metallic);
    out.rim_pad = vec2<f32>(inst.rim, 0.0);

    if (inst.visible <= 0.0) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        return out;
    }

    let world_p4 = inst.model * vec4<f32>(v.pos, 1.0);
    let c0 = inst.model[0].xyz;
    let c1 = inst.model[1].xyz;
    let c2 = inst.model[2].xyz;
    let cof = mat3x3<f32>(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    let det = dot(c0, cof[0]);
    let n_sign = select(1.0, -1.0, det < 0.0);
    let n_raw = cof * v.normal * n_sign;
    let n_len2 = dot(n_raw, n_raw);
    out.world_pos = world_p4.xyz;
    out.world_normal = select(vec3<f32>(0.0, 1.0, 0.0), n_raw * inverseSqrt(n_len2), n_len2 > 1e-12);

    var clip = cam.proj * (cam.view * world_p4);
    let orbit_ndc = vec2<f32>(
        -2.0 * g.orbit.x / max(g.canvas.x, 1.0),
        2.0 * g.orbit.y / max(g.canvas.y, 1.0),
    );
    clip = vec4<f32>(clip.xy + orbit_ndc * clip.w, clip.z, clip.w);
    if (!mesh_is_finite_vec4(clip)) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        return out;
    }
    out.clip_pos = clip;
    return out;
}

fn mesh_fragment(in: MeshVsOut, cam: MeshCamera, front_facing: bool) -> vec4<f32> {
    let n2 = dot(in.world_normal, in.world_normal);
    var n = select(vec3<f32>(0.0, 1.0, 0.0), in.world_normal * inverseSqrt(n2), n2 > 1e-10);
    if (!front_facing) {
        n = -n;
    }

    let to_eye = cam.eye - in.world_pos;
    let d2 = dot(to_eye, to_eye);
    let dist = sqrt(max(d2, 0.0));
    let v = select(vec3<f32>(0.0, 0.0, 1.0), to_eye / max(dist, 1e-5), d2 > 1e-10);

    let l2 = dot(cam.light_dir, cam.light_dir);
    let l_dir = select(vec3<f32>(0.0, 1.0, 0.0), cam.light_dir * inverseSqrt(l2), l2 > 1e-10);
    let f2 = dot(cam.fill_dir, cam.fill_dir);
    let f_dir = select(vec3<f32>(0.0, -1.0, 0.0), cam.fill_dir * inverseSqrt(f2), f2 > 1e-10);

    let albedo = max(in.color_rough.rgb, vec3<f32>(0.0));
    let rough = clamp(in.color_rough.w, 0.05, 1.0);
    let emissive = max(in.emissive_metal.rgb, vec3<f32>(0.0));
    let metal = clamp(in.emissive_metal.w, 0.0, 1.0);
    let rim = max(in.rim_pad.x, 0.0);

    let diff_key = max(dot(n, l_dir), 0.0);
    let diff_fill = max(dot(n, f_dir), 0.0);
    let h_dir = normalize(l_dir + v);
    let spec_pow = mix(96.0, 8.0, rough * rough);
    let spec = pow(max(dot(n, h_dir), 0.0), spec_pow) * step(0.0, dot(n, l_dir));
    let spec_tint = mix(vec3<f32>(1.0), albedo, metal);
    let spec_strength = mix(0.65, 0.10, rough);

    let diffuse_base = albedo * (1.0 - metal * 0.65);
    let hemi = cam.ambient * (0.65 + 0.35 * n.y);
    let rim_term = fresnel(n, v, mix(3.2, 1.8, rough)) * rim * mix(albedo, vec3<f32>(1.0), 0.45);

    var lit = diffuse_base * (diff_key * cam.light_col + diff_fill * cam.fill_col + hemi)
        + spec_tint * (spec * spec_strength * cam.light_col)
        + rim_term
        + emissive;

    if (cam.fog_density > 0.0) {
        lit = fog_exp(lit, vec3<f32>(0.0), dist, cam.fog_density);
    }
    return vec4<f32>(clamp(lit, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
