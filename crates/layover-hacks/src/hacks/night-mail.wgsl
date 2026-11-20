// Night Mail: a mail train crosses dark hills while the moon climbs across
// the sky and the stars drift. Everything bright moves: the moon crosses
// the canvas in six minutes, the train passes every two, and the signal
// lamps scroll with the near hills.

fn hills(x: f32, base: f32, amp: f32, k: f32) -> f32 {
    return base + amp * (sin(x * 2.1 * k + 1.3) * 0.5 + sin(x * 5.7 * k + 0.4) * 0.3 + sin(x * 13.0 * k) * 0.2);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    var col = mix(vec3<f32>(0.05, 0.07, 0.12), vec3<f32>(0.015, 0.02, 0.045), p.y);

    // Stars drift slowly to the left and twinkle.
    let sp = vec2<f32>(p.x + t * 0.003, p.y) * 90.0;
    let cell = floor(sp);
    let h = hash21(cell + g.seed);
    if (h > 0.975 && p.y > 0.3) {
        let o = (hash22(cell) - 0.5) * 0.6;
        let d = length(fract(sp) - 0.5 - o);
        let tw = 0.45 + 0.4 * sin(t * (0.6 + h * 2.0) + h * 50.0);
        col = col + vec3<f32>(0.8, 0.82, 0.9) * disc(d, 0.09, 0.06) * tw;
    }

    // The moon rises on the right and sets on the left, every six minutes.
    let mp = fract(t / 360.0 + g.seed * 0.37);
    let m = vec2<f32>(mix(a + 0.25, -0.25, mp), 0.42 + 0.36 * sin(mp * PI));
    let md = length(p - m);
    let lit = disc(md, 0.065, 0.006) * (1.0 - disc(length(p - m - vec2<f32>(0.028, 0.012)), 0.06, 0.006));
    col = col + vec3<f32>(0.85, 0.86, 0.82) * lit + vec3<f32>(0.3, 0.32, 0.38) * 0.12 * exp(-md * 7.0);

    // Far and near hills scroll at different speeds.
    let far = hills(p.x + t * 0.006, 0.31, 0.07, 1.0);
    if (p.y < far) {
        col = vec3<f32>(0.04, 0.055, 0.09);
    }
    let near = hills(p.x + t * 0.018 + 7.0, 0.23, 0.05, 1.6);
    if (p.y < near) {
        col = vec3<f32>(0.025, 0.033, 0.055);
    }

    // The embankment and the rails.
    let ty = 0.15;
    if (p.y < ty) {
        col = vec3<f32>(0.015, 0.02, 0.03);
    }
    col = col + vec3<f32>(0.12, 0.13, 0.16) * (1.0 - smoothstep(0.0, 0.003, abs(p.y - ty))) * 0.6;

    // Signal posts scroll with the near hills; their lamps change aspect.
    let gap = 0.9;
    let sx = p.x + t * 0.018;
    let si = floor(sx / gap);
    let lx = (si + 0.5) * gap - t * 0.018;
    let mast = 1.0 - smoothstep(0.0, 0.002, abs(p.x - lx));
    if (p.y > ty && p.y < ty + 0.14) {
        col = mix(col, vec3<f32>(0.06, 0.07, 0.09), mast);
    }
    let lamp = select(vec3<f32>(0.75, 0.25, 0.28), vec3<f32>(0.45, 0.8, 0.35), hash11(si * 3.1 + floor(t / 40.0)) > 0.4);
    let ld = length(p - vec2<f32>(lx, ty + 0.145));
    col = col + lamp * (disc(ld, 0.007, 0.003) + 0.25 * exp(-ld * 60.0));

    // The train: a locomotive and five lit carriages, every two minutes.
    let car_w = 0.2;
    let car_gap = 0.012;
    let cars = 6.0;
    let train = cars * (car_w + car_gap);
    let span = a + train + 1.2;
    let rear = fract(t * 0.05 / span + g.seed * 0.71) * span - train - 0.6;
    let x = p.x - rear;
    let y = p.y - ty - 0.004;
    let car_h = 0.065;
    if (x > 0.0 && x < train && y > 0.0 && y < car_h) {
        let ci = floor(x / (car_w + car_gap));
        let cx = x - ci * (car_w + car_gap);
        if (cx < car_w) {
            col = vec3<f32>(0.05, 0.055, 0.075);
            let wi = floor(cx / car_w * 6.0);
            let wx = fract(cx / car_w * 6.0);
            let wy = y / car_h;
            let on = hash11(ci * 7.0 + wi + floor(g.seed * 10.0)) > 0.2;
            if (ci < cars - 1.0 && on && wx > 0.22 && wx < 0.78 && wy > 0.38 && wy < 0.78) {
                col = vec3<f32>(0.95, 0.78, 0.48) * (0.85 + 0.15 * sin(t * 5.0 + ci * 2.0 + wi));
            }
        }
    }
    // The headlamp's beam ahead of the locomotive.
    let front = rear + train;
    let ahead = p.x - front;
    if (ahead > 0.0 && ahead < 0.5) {
        let spread = 0.012 + ahead * 0.12;
        let beam = (1.0 - smoothstep(0.0, spread, abs(p.y - (ty + 0.03)))) * (1.0 - ahead / 0.5);
        col = col + vec3<f32>(0.7, 0.72, 0.65) * beam * 0.25;
    }
    return col;
}
