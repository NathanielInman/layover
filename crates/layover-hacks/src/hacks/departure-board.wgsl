// Departure Board: the line on a split-flap board, one row from each tool
// on the desk (states and counts only). Text is the hardest thing on a
// panel, so rule one is built in: the board drifts slowly on two unequal
// periods inside its margins, every 8 seconds the rows shift up a slot with
// a flap, its neutral text turns its own hue (the care pass leaves this
// hack's hue alone so the status colors keep their meaning), and it hands
// off after care.text_rotate.
//
// Needs the board binding: `board`, `FONT`, `board_changed(i)`.

const SLOTS: u32 = 6u;
const PAGE: f32 = 8.0;

fn glyph_bit(gl: u32, x: i32, y: i32) -> bool {
    if (x < 0 || x > 4 || y < 0 || y > 6) {
        return false;
    }
    let bits = FONT[gl * 7u + u32(y)];
    return ((bits >> u32(4 - x)) & 1u) == 1u;
}

fn tone_color(tone: u32, neutral: vec3<f32>) -> vec3<f32> {
    switch tone {
        case 1u: { return vec3<f32>(0.62, 0.74, 0.52); }
        case 2u: { return vec3<f32>(0.9, 0.76, 0.5); }
        case 3u: { return vec3<f32>(0.82, 0.42, 0.46); }
        case 4u: { return vec3<f32>(0.42, 0.45, 0.5); }
        default: { return neutral; }
    }
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let background = vec3<f32>(0.004, 0.005, 0.008);
    let cols = f32(board.cols);
    let lines = f32(SLOTS + 1u);
    // A tile is 1.5 wide-units tall; lines sit 1.3 tiles apart.
    let cw = min(0.8 * a / cols, 0.7 / (lines * 1.5 * 1.3));
    let ch = cw * 1.5;
    let lh = ch * 1.3;
    let bw = cw * cols;
    let bh = lh * lines;
    // Drift inside the margins, never resting on both axes at once.
    let mx = max(0.0, (a - bw) * 0.5 - 0.02);
    let my = max(0.0, (1.0 - bh) * 0.5 - 0.02);
    let ox = (a - bw) * 0.5 + mx * 0.92 * sin(t * 0.047 + g.seed * 6.0);
    let oy = (1.0 - bh) * 0.5 + my * 0.92 * sin(t * 0.061 + 1.3 + g.seed);
    let lx = p.x - ox;
    let ly = (1.0 - p.y) - oy;
    if (lx < 0.0 || lx >= bw || ly < 0.0 || ly >= bh) {
        return background;
    }
    let line = u32(floor(ly / lh));
    let c = u32(floor(lx / cw));
    let fy = (ly - f32(line) * lh) / ch;
    let fx = fract(lx / cw);
    if (fy > 1.0 || fx < 0.06 || fx > 0.94) {
        return background;
    }
    var col = vec3<f32>(0.03, 0.033, 0.04);
    if (abs(fy - 0.5) < 0.03) {
        col = vec3<f32>(0.01, 0.011, 0.014);
    }

    // Which row of the buffer this slot shows, and when it last flipped.
    var row = 0u;
    var changed = board_changed(0u);
    if (line > 0u) {
        let shown = max(board.shown, 1u);
        let slot = line - 1u;
        if (slot >= shown) {
            return col;
        }
        let page = floor(t / PAGE);
        row = 1u + (slot + u32(page)) % shown;
        changed = max(page * PAGE, board_changed(row));
    }
    let cell = board.cells[row * board.cols + c];
    var gl = cell & 0xffu;
    let tone = (cell >> 8u) & 0xffu;
    // The flap: for a moment after a change, letters spin past.
    let since = t - changed - f32(c) * 0.02;
    if (since >= 0.0 && since < 0.42 && gl != 0u) {
        gl = 1u + u32(hash21(vec2<f32>(f32(c) + f32(row) * 61.0, floor(t * 20.0))) * 35.99);
    }
    let gx = (fx - 0.16) / 0.68 * 5.0;
    let gy = (fy - 0.1) / 0.8 * 7.0;
    if (glyph_bit(gl, i32(floor(gx)), i32(floor(gy)))) {
        let d = length(fract(vec2<f32>(gx, gy)) - 0.5);
        let dot = 1.0 - smoothstep(0.3, 0.46, d);
        let h = t * TAU / 360.0;
        let neutral = vec3<f32>(0.6) + 0.12 * vec3<f32>(cos(h), cos(h - 2.094), cos(h + 2.094));
        col = mix(col, tone_color(tone, neutral), dot);
    }
    return col;
}
