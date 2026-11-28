//! The Departure Board's data: a 5 × 7 dot-matrix font, the cell grid the
//! shader reads, and the composer that lays rows from the line into it.
//!
//! The grid is a header row and up to `DATA_ROWS` rows of `COLS` cells. A
//! cell is a glyph index and a tone (`glyph | tone << 8`). Times when a row
//! last changed (in hack seconds) drive the split-flap animation.

use bytemuck::{Pod, Zeroable};
use layover_core::feeds::{Row, Tone};

/// Every character the board can show; anything else is a space.
pub const CHARSET: &str = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:·-./%";

/// Cells across: TIME 5, WHAT 22, FROM 10, STATUS 10, and a space between.
pub const COLS: usize = 50;
pub const DATA_ROWS: usize = 8;
pub const ROWS: usize = DATA_ROWS + 1;
/// Cells, padded so the buffer is a multiple of 16 bytes.
pub const CELLS: usize = (ROWS * COLS).div_ceil(4) * 4;

const TIME_AT: usize = 0;
const WHAT_AT: usize = 6;
const FROM_AT: usize = 29;
const STATUS_AT: usize = 40;

/// Tones as the shader numbers them.
pub const TONE_NEUTRAL: u32 = 0;
fn tone_code(t: Tone) -> u32 {
    match t {
        Tone::Calm => 1,
        Tone::Busy => 2,
        Tone::Alert => 3,
        Tone::Quiet => 4,
    }
}

/// Rows of 5 bits, top first, most significant bit on the left.
#[rustfmt::skip]
const FONT: [[u8; 7]; 43] = [
    [0, 0, 0, 0, 0, 0, 0], // space
    [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001], // A
    [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110], // B
    [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110], // C
    [0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100], // D
    [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111], // E
    [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000], // F
    [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111], // G
    [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001], // H
    [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110], // I
    [0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100], // J
    [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001], // K
    [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111], // L
    [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001], // M
    [0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001], // N
    [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110], // O
    [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000], // P
    [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101], // Q
    [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001], // R
    [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110], // S
    [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100], // T
    [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110], // U
    [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100], // V
    [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010], // W
    [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001], // X
    [0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100], // Y
    [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111], // Z
    [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110], // 0
    [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110], // 1
    [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111], // 2
    [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110], // 3
    [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010], // 4
    [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110], // 5
    [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110], // 6
    [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000], // 7
    [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110], // 8
    [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100], // 9
    [0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000], // :
    [0b00000, 0b00000, 0b00000, 0b01100, 0b01100, 0b00000, 0b00000], // ·
    [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000], // -
    [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100], // .
    [0b00000, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000], // /
    [0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011], // %
];

/// The font as a WGSL constant, for hacks that draw text.
pub fn font_wgsl() -> String {
    let words: Vec<String> = FONT.iter().flatten().map(|b| format!("{b}u")).collect();
    format!(
        "const FONT: array<u32, {}> = array<u32, {}>({});\n",
        words.len(),
        words.len(),
        words.join(", ")
    )
}

/// A character's dot rows (top first, five bits each), for text drawn on
/// the CPU such as Audition's strip. Anything outside `CHARSET` is a space.
pub fn glyph_rows(c: char) -> [u8; 7] {
    FONT[glyph(c) as usize]
}

fn glyph(c: char) -> u32 {
    CHARSET.chars().position(|g| g == c.to_ascii_uppercase()).unwrap_or(0) as u32
}

/// What the shader reads: sizes, change times, then the cells.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct BoardData {
    pub cols: u32,
    pub rows: u32,
    /// Data rows in use (the shader cycles through them).
    pub shown: u32,
    pub _pad: u32,
    /// When each row (header first) last changed, in hack seconds.
    pub changed: [f32; 12],
    pub cells: [u32; CELLS],
}

impl Default for BoardData {
    fn default() -> Self {
        Self::zeroed()
    }
}

impl BoardData {
    fn put(&mut self, row: usize, at: usize, text: &str, width: usize, tone: u32) {
        for (i, c) in text.chars().take(width).enumerate() {
            self.cells[row * COLS + at + i] = glyph(c) | tone << 8;
        }
    }

    /// Lay out the header (`clock` is `14:28`) and the rows. `times[i]` is
    /// when row `i` last changed, `HH:MM`; `changed` is the same in hack
    /// seconds, header first.
    pub fn compose(rows: &[Row], times: &[String], clock: &str, changed: &[f32]) -> BoardData {
        let mut b = BoardData { cols: COLS as u32, rows: ROWS as u32, ..BoardData::default() };
        b.put(0, 0, "DEPARTURES · THE LINE", COLS, TONE_NEUTRAL);
        b.put(0, COLS - clock.chars().count().min(5), clock, 5, TONE_NEUTRAL);
        if rows.is_empty() {
            b.put(1, WHAT_AT, "NOTHING ON THE LINE", 22, TONE_NEUTRAL);
            b.shown = 1;
        }
        for (i, r) in rows.iter().take(DATA_ROWS).enumerate() {
            let line = i + 1;
            b.put(
                line,
                TIME_AT,
                times.get(i).map(String::as_str).unwrap_or("--:--"),
                5,
                TONE_NEUTRAL,
            );
            b.put(line, WHAT_AT, &r.what, 22, TONE_NEUTRAL);
            b.put(line, FROM_AT, &r.from, 10, TONE_NEUTRAL);
            b.put(line, STATUS_AT, &r.status, 10, tone_code(r.tone));
            b.shown = line as u32;
        }
        for (i, t) in changed.iter().take(12).enumerate() {
            b.changed[i] = *t;
        }
        b
    }

    /// Rows the wear test and the hero use: one from each tool, as they
    /// might read on a working day.
    pub fn sample() -> BoardData {
        let r = |what: &str, from: &str, status: &str, tone| Row {
            what: what.into(),
            from: from.into(),
            status: status.into(),
            tone,
        };
        let rows = [
            r("MEETING", "TIMETABLE", "IN 7M", Tone::Busy),
            r("2 BUILDS", "SWITCHYARD", "BUILDING", Tone::Busy),
            r("33 TASKS WAIT ON YOU", "WAYBILL", "WAITING", Tone::Busy),
            r("AGENT ASKS FOR A KEY", "SIGNAL BOX", "TOUCH KEY", Tone::Alert),
            r("MACHINE", "ROUNDHOUSE", "FIT TO RUN", Tone::Calm),
            r("WORK VPN", "TABLET", "UP", Tone::Calm),
            r("MIC", "LOGBOOK", "OFF AIR", Tone::Calm),
            r("MUSIC", "TANNOY", "PAUSED", Tone::Quiet),
        ];
        let times: Vec<String> =
            ["14:21", "14:02", "13:40", "14:26", "09:15", "12:58", "14:10", "13:55"]
                .map(String::from)
                .to_vec();
        BoardData::compose(&rows, &times, "14:28", &[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_font_covers_the_charset() {
        assert_eq!(FONT.len(), CHARSET.chars().count());
        assert!(FONT.iter().flatten().all(|r| *r < 32));
    }

    #[test]
    fn every_word_a_feed_writes_is_in_the_charset() {
        let words = "MEETING STARTS NOW SOON IN 7M LEFT LATER FOCUS BLOCK ON YOUR OWN TIME CALENDAR OFFLINE \
            FREE BUILDS FAILED BUILDING QUEUED TASKS RUNNING OK ALL QUIET 33 WAIT WAITS YOU WAITING CLEAR \
            NOTHING AGENT ASKS FOR A KEY TOUCH REQUEST MISSED GRANT ENDING GRANTS LIVE SECRETS LOCKED \
            MACHINE NEEDS HEADS UP FIT TO RUN WORK VPN STALE DOWN CONNECTING OFF AIR RECORDING DICTATING \
            TRANSCRIPT MIC USE MUSIC PLAYING PAUSED HIDDEN DEPARTURES · THE LINE 14:28 SIGNAL BOX";
        for c in words.chars() {
            assert!(c == ' ' || glyph(c) != 0, "`{c}` is not on the board");
        }
    }

    #[test]
    fn rows_land_in_their_columns() {
        let b = BoardData::sample();
        let row: String = (0..COLS)
            .map(|i| CHARSET.chars().nth((b.cells[COLS + i] & 0xff) as usize).unwrap())
            .collect();
        assert_eq!(&row[TIME_AT..TIME_AT + 5], "14:21");
        assert!(row[WHAT_AT..].starts_with("MEETING"));
        assert!(row[FROM_AT..].starts_with("TIMETABLE"));
        assert!(row[STATUS_AT..].starts_with("IN 7M"));
        assert_eq!(b.cells[COLS + STATUS_AT] >> 8, tone_code(Tone::Busy));
        assert_eq!(b.shown, 8);
        assert_eq!(size_of::<BoardData>() % 16, 0, "storage buffers want 16-byte sizes");
    }
}
