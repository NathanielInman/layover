// The limiter: holds every frame under care.max_average (rule one). See
// "Hacks" in docs/design.md.

struct Limit {
    drive: f32,
    max_average: f32,
    dt: f32,
    _pad: f32,
};

@group(0) @binding(0) var hack_tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> limit: Limit;
@group(0) @binding(2) var<storage, read_write> gain: array<f32, 2>;

const GRID_X: u32 = 64u;
const GRID_Y: u32 = 18u;

var<workgroup> partial: array<f32, 64>;

// Measures the average level on a 64 x 18 grid and eases the gain toward
// what keeps the frame under care.max_average. gain[0] is the gain, gain[1]
// the last measured average.
@compute @workgroup_size(64)
fn measure(@builtin(local_invocation_index) li: u32) {
    let size = vec2<f32>(textureDimensions(hack_tex));
    var sum = 0.0;
    for (var y = 0u; y < GRID_Y; y = y + 1u) {
        let uv = (vec2<f32>(f32(li), f32(y)) + 0.5) / vec2<f32>(f32(GRID_X), f32(GRID_Y));
        let c = textureLoad(hack_tex, vec2<i32>(uv * size), 0).rgb;
        sum = sum + (c.r + c.g + c.b) / 3.0;
    }
    partial[li] = sum;
    workgroupBarrier();
    if (li == 0u) {
        var total = 0.0;
        for (var i = 0u; i < GRID_X; i = i + 1u) {
            total = total + partial[i];
        }
        let average = total / f32(GRID_X * GRID_Y) * limit.drive;
        let target_gain = min(1.0, limit.max_average / max(average, 0.0001));
        var current = gain[0];
        if (current <= 0.0) {
            current = target_gain;
        }
        // Dim fast, brighten slowly.
        var tau = 2.0;
        if (target_gain < current) {
            tau = 0.25;
        }
        let k = 1.0 - exp(-limit.dt / tau);
        gain[0] = current + (target_gain - current) * k;
        gain[1] = average;
    }
}
