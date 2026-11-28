//! Audition's strip: a few lines of the Departure Board's dot-matrix font
//! drawn on the CPU into a buffer for a small layer surface over the
//! saver. Pure, so a test can look at it.

use layover_hacks::board::glyph_rows;

/// Dots per font pixel.
pub const SCALE: usize = 2;
/// One character cell: five dots and a gap.
pub const CELL_W: usize = 6 * SCALE;
/// One line: seven dots and a gap.
pub const LINE_H: usize = 10 * SCALE;
/// Space around the text.
pub const PAD: usize = 10;

/// The brightest any channel of the strip may be: 70% of full.
pub const MAX_LEVEL: u8 = 178;

/// A line of text in a color (RGB, 0 to 255).
pub struct Line {
    pub text: String,
    pub color: [u8; 3],
}

/// Glyphs the board's font lacks, drawn here for the strip only.
fn extra(c: char) -> Option<[u8; 7]> {
    Some(match c {
        '<' => [0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010],
        '>' => [0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000],
        '*' => [0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000],
        '+' => [0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000],
        _ => return None,
    })
}

/// The size a strip of `lines` needs, in pixels.
pub fn size(lines: &[Line]) -> (usize, usize) {
    let cols = lines.iter().map(|l| l.text.chars().count()).max().unwrap_or(0);
    (cols * CELL_W + 2 * PAD, lines.len() * LINE_H + 2 * PAD - 2 * SCALE)
}

/// Draws `lines` centered on a dark plate into `w` × `h` premultiplied
/// ARGB (little-endian, as wl_shm's Argb8888), with everything scaled by
/// `fade` (0 to 1).
pub fn draw(lines: &[Line], w: usize, h: usize, fade: f32) -> Vec<u8> {
    let mut buf = vec![0u8; w * h * 4];
    let fade = fade.clamp(0.0, 1.0);
    let (tw, th) = size(lines);
    let (ox, oy) = ((w.saturating_sub(tw)) / 2, (h.saturating_sub(th)) / 2);
    let mut put = |x: usize, y: usize, rgb: [u8; 3], a: f32| {
        if x >= w || y >= h {
            return;
        }
        let i = (y * w + x) * 4;
        let a = (a * fade).clamp(0.0, 1.0);
        let c = |v: u8| (v.min(MAX_LEVEL) as f32 * a) as u8;
        buf[i] = c(rgb[2]);
        buf[i + 1] = c(rgb[1]);
        buf[i + 2] = c(rgb[0]);
        buf[i + 3] = (a * 255.0) as u8;
    };
    // The plate: dim, so it never becomes the brightest thing on the panel.
    for y in oy..(oy + th).min(h) {
        for x in ox..(ox + tw).min(w) {
            put(x, y, [10, 11, 13], 0.82);
        }
    }
    for (row, line) in lines.iter().enumerate() {
        let n = line.text.chars().count();
        let lx = ox + PAD + ((tw - 2 * PAD) - n * CELL_W) / 2;
        let ly = oy + PAD + row * LINE_H;
        for (col, c) in line.text.chars().enumerate() {
            let rows = extra(c).unwrap_or_else(|| glyph_rows(c));
            for (dy, bits) in rows.iter().enumerate() {
                for dx in 0..5 {
                    if bits & (0b10000 >> dx) == 0 {
                        continue;
                    }
                    for sy in 0..SCALE {
                        for sx in 0..SCALE {
                            let x = lx + col * CELL_W + dx * SCALE + sx;
                            let y = ly + dy * SCALE + sy;
                            put(x, y, line.color, 1.0);
                        }
                    }
                }
            }
        }
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_strip_draws_its_text_on_a_dim_plate_and_fades() {
        let lines = vec![
            Line { text: "< LAVA DRIFT 3/33 >".into(), color: [150, 160, 170] },
            Line { text: "IN ROTATION *".into(), color: [140, 170, 120] },
        ];
        let (w, h) = size(&lines);
        assert_eq!(w, 19 * CELL_W + 2 * PAD);
        let full = draw(&lines, w, h, 1.0);
        let lit = full.as_chunks::<4>().0.iter().filter(|p| p[2] > 100).count();
        assert!(lit > 100, "text is drawn: {lit}");
        let plate = full.as_chunks::<4>().0.iter().filter(|p| p[3] > 0 && p[2] < 20).count();
        assert!(plate > lit, "on a plate");
        let none = draw(&lines, w, h, 0.0);
        assert!(none.iter().all(|b| *b == 0), "faded out is clear");
        // Nothing on the strip goes past 70% of full (rule one).
        assert!(full.as_chunks::<4>().0.iter().all(|p| p[..3].iter().all(|c| *c <= MAX_LEVEL)));
    }
}
