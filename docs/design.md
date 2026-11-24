# Layover design

Layover is a screensaver for Wayland desktops: one daemon that runs the idle
line (saver, lock, dark), GPU hacks drawn on overlay layer surfaces, and a
lamp in waybar. A layover is the rest a train crew takes between runs.

This file is the spec. The README is the tour.

## Rule one: every hack wears the panel evenly, gently and briefly

Burn-in is uneven wear: some subpixels age faster than their neighbors because
they were driven brighter or longer. Black costs an OLED nothing, and wear
spread evenly across the panel never shows. Every hack Layover ships, every
classic hack it runs and its lock screen follow these rules, on every panel,
OLED or not.

1. **Nothing holds still.** A lit pixel changes within `care.max_dwell`.
   Anything that must stay up drifts, and the whole frame orbits on
   `care.orbit`.
2. **Dim by default.** Frames are mostly black. The care pass scales every
   subpixel by `care.max_drive`, and an average limiter holds the frame's
   average picture level under `care.max_average`.
3. **Share the load across subpixels.** The care pass turns hues through the
   color wheel on `care.hue_cycle`, so red, green and blue age together, and
   caps light where all three are lit at once (`care.max_white`). No hack
   leans on one channel.
4. **Take turns, then rest.** Hacks hand off every `care.rotate`
   (`care.text_rotate` for text-heavy ones). The run ends in dark.
5. **Measured, not eyeballed.** Every hack passes the wear test
   (`layover-hacks/src/wear.rs`) against the shipped budget before it ships.
   A failing hack is a failing build.
6. **Safe defaults, honest warnings.** Every limit can be changed. The shipped
   config says why each one exists and warns that raising it puts the
   monitor at risk. `layover check`, the daemon log and the lamp's tooltip
   list every value looser than shipped.

A change that weakens any of these needs its own commit that says so.

## The idle line

Three stations and a lock, measured from the last input:

| Station | Default | What happens |
| --- | --- | --- |
| Saver | `15m` | A hack starts on every output. Any input dismisses it. |
| Lock | `dark` | The lock command runs (hyprlock until Layover's own lock). |
| Dark | `1h` | Every output's power goes off. |

`line.saver` and `line.dark` take a duration of at least `1m`, or `"off"`.
`line.lock` takes a duration, `"dark"` (lock as the screens go off) or
`"off"`. While a lock client is running and the screens are on,
they go dark after `line.locked_dark` (default `1m`) idle: hyprlock's
screenshot and clock sit still.

Idle comes from `ext-idle-notify-v1`. Version 2's
`get_input_idle_notification` ignores idle inhibitors, so Layover reads them
itself (see holds) and can skip the ones that are always on. Without
version 2 Layover falls back to `get_idle_notification`, logs that inhibitors
can no longer be filtered, and every inhibitor holds the line.

Output power uses `zwlr_output_power_manager_v1`. Without it the daemon runs
`line.dark_command` and `line.wake_command` when set, and otherwise logs that
it cannot turn the screens off.

### Holds

When a station is reached, the daemon checks what holds it:

| Hold | Source | Holds |
| --- | --- | --- |
| Inhibitor | Hyprland clients with `inhibitingIdle`, minus `holds.ignore` | saver, lock, dark |
| Microphone | an uncorked `pactl` source output that is not a level meter | saver, lock, dark |
| Audio | an uncorked, unmuted `pactl` sink input | `holds.audio`: `"dark"` (default), `"all"` or `"off"` |
| On air | Logbook recording or dictating (the line), `feeds.hold_on_air` | saver, lock, dark |
| Meeting soon | Timetable's `soon` or `now` (the line), `feeds.hold_meeting` | saver |
| Manual | `layover hold <duration>` | saver, lock, dark |

Audio holds only the dark by default: a static desktop while music plays is
the worst case for a panel, and a hack under the care rules is not. A held
station is checked again every 60 seconds while the desk stays idle.

Streams come from `pactl -f json list sink-inputs` and `source-outputs`, the
view sway-audio-idle-inhibit uses, run only when a station is reached. ALSA's
status can't tell a device PipeWire holds open from one that is recording.

### The state machine

`layover-core/src/state.rs` is pure: events in (a station reached with the
holds at that moment, input resumed, a command, the saver exiting, a tick),
effects out (start or stop the saver, run the lock, power outputs off or on,
publish the lamp). Every rule about what the daemon does lives there with a
test.

## The line

Layover reads the other tools on the desk the way waybar does: it runs each
one's `bar` command (`[feeds]`: `timetable bar`, `yard bar`, `waybill bar`,
`broker bar`, `rh bar`, `tablet bar`, `logbook bar`, `tannoy bar`) and reads
the lamp lines it prints (text, class as a string or a list, tooltip). Each
feed is a child of the daemon with `PR_SET_PDEATHSIG`, read on its own
thread, and started again with backoff (2 s doubling to a minute) when it
ends. A command that isn't installed is skipped and named once in the log;
`[]` turns a feed off.

`layover-core/src/feeds.rs` turns a lamp into a reading, pure and tested
against recorded lamps:

| Tool | Read from | Gives |
| --- | --- | --- |
| Timetable | `now`, `soon`, `in`, `next`, `focus`, `own`, `free`; minutes from "in 7m" | meeting soon (`soon`, `now`), a row |
| Switchyard | `building`, `queued` (the main line), `running`, `ok`, `failed`; a count in the text | heavy build, a row |
| Waybill | "N tasks wait on you" in the tooltip | a row |
| Signal Box | `asking`, `live` with its count, `ending`, `missed`, `locked` | a row |
| Roundhouse | `heads-up` or `act` with a heat bullet (°C) in the tooltip | hot, a row |
| Tablet | `held`, `stale`, `dropped`, `connecting`, `off` | a row |
| Logbook | `recording`, `dictating` (on air), `mic`, `transcribing` | on air, a row |
| Tannoy | `playing`, `paused`, `hidden` | a row |

**Privacy.** A row carries states and counts only, in Layover's own words:
"MEETING IN 7M", "33 TASKS WAIT ON YOU", "AGENT ASKS FOR A KEY". Nothing
copies free text from a lamp into a row, so song titles, meeting names,
secret names and task text never reach the screen; a test checks recorded
lamps for leaks.

**Cheap mode.** While Switchyard builds on its main line or Roundhouse warns
about heat (and `feeds.cheap` is on), the saver draws at half the frame
rate, half the render size and three quarters of the drive. Motion keeps its
speed, so dwell and the wear test are unchanged; only the GPU's share goes
down. It comes and goes as the line changes, is written to the history, and
shows in the lamp's tooltip and the drawer.

## Hacks

A hack is a WGSL fragment function in `layover-hacks/src/hacks/`:

```wgsl
fn hack(p: vec2<f32>, t: f32) -> vec3<f32>
```

`p` is the position on the canvas in canvas heights: `y` runs from 0 at the
bottom to 1 at the top and `x` from 0 to the canvas aspect. The canvas is the
bounding box of every output, so a G9 split into two outputs gets one 32:9
picture. `t` is seconds since the saver started. The prelude
(`hacks/prelude.wgsl`) has the uniforms, hashes, noise and 3D SDF primitives;
a hack with `raymarch: true` also gets `hacks/raymarch.wgsl` (sphere tracing,
tetrahedron normals, ambient occlusion and soft shadows over its `sdf(p, t)`),
and a hack with `feedback: Some(...)` gets `hacks/feedback.wgsl` and ping-pong
`Rgba16Float` state textures stepped by `step_state(uv, p, t)` with per-hack
exponential fade (`g.fade = exp(-dt / fade_secs)`).

Each frame:

1. Stateful hacks (`feedback`) first step their ping-pong state texture through
   `step_state`, fading older history on the hack's clock.
2. The hack pass draws the whole canvas into one offscreen texture at
   `power.render_scale`, with the orbit offset added to every position.
3. The limiter pass measures the average level on a sparse grid and eases a
   gain toward `care.max_average`.
4. A care pass per output samples that output's part of the texture (using
   lightweight FXAA when `saver.antialias` is on and the hack is not
   text-heavy) and applies, in order: hue turn (if the hack allows it), drive
   scale, limiter gain, white cap and fade.

Hacks hand off with a fade through black. Text-heavy hacks declare it and use
`care.text_rotate`.

### The Departure Board

`departure-board` draws the line: a header ("DEPARTURES · THE LINE" and the
clock) over a row per tool with TIME (when the row last changed), WHAT, FROM
and STATUS, the last colored by the row's tone (calm, busy, alert, quiet).
Letters are a 5 × 7 dot-matrix font (`layover-hacks/src/board.rs`) on
split-flap tiles. A hack with `board: true` gets a second bind group holding
the cells (`glyph | tone << 8`) and when each row changed; the font is a WGSL
constant built from the Rust table.

Rule one for text: the board drifts on two unequal periods inside its
margins, every 8 seconds the rows shift up a slot with a flap, it turns its
own neutral hue (the care pass leaves `hue_turn` off so the status colors
keep their meaning), and it hands off after `care.text_rotate`. It passes the
wear test on sample rows.

The saver gets the rows from the daemon's `line` subscription and uploads
them only when a row or the clock changes. Without a daemon it says nothing
is on the line.

### The wear test

`layover-hacks/src/wear.rs` renders a hack headless at 256 × 72 for a
simulated hour, one frame per second, through the same care pass, and
measures:

| Metric | Budget |
| --- | --- |
| Average picture level | `care.max_average` |
| Longest lit dwell: a pixel above 15% that changed by less than 3% in a second | `care.max_dwell` |
| Hottest area: the highest per-pixel average level | `care.max_hot_spot` |
| Channel share: each of red, green and blue as a share of all light | 40% |
| Peak drive | `care.max_drive` |

`cargo test` runs it for every hack against the shipped budget (it needs a
GPU adapter; CI uses Mesa's lavapipe). Stateful hacks run with their
persistent ping-pong state from a fixed seed so accumulation and fades are
measured, and a test verifies that an unfaded stateful hack fails the dwell
budget. `layover wear <hack>` runs it against your config and writes a heat map
PNG.

## Config

`[bar]`, `[drawer]` and `[theme]` set where the drawer opens from, its size
and its look; the rest is the idle line, holds, care, power and the saver
(`hacks` and `antialias`, which defaults to `true`).

`~/.config/layover/layover.toml` (`$LAYOVER_CONFIG_DIR` overrides the
directory). `packaging/examples/config.toml` is the shipped file with every
key, its reason and its warning; a test checks it parses to the built-in
defaults.

## Processes and files

- `layover daemon`: the idle line. One Wayland connection for idle and output
  power, a Unix socket at `$XDG_RUNTIME_DIR/layover/daemon.sock`, and the saver
  as a child process.
- `layover saver`: the overlay surfaces and the renderer. The daemon starts it
  and stops it with SIGTERM; it also exits on its own on any key, button or
  pointer movement past a few pixels.
- `layover bar`: the waybar module, one JSON line per lamp change.
- `layover doctor`: one `ok`, `fail` or `info` line per check: the config
  and its hacks, the daemon (a `status` request) and `layover.service`, the
  compositor's `ext_idle_notifier_v1`, `zwlr_layer_shell_v1` and
  `zwlr_output_power_manager_v1` (or `line.dark_command`), a Vulkan adapter,
  `pactl`, Hyprland's socket when `holds.inhibitors` is on, the lock and dark
  commands, the feeds, the waybar module, `layover-board` and GTK 4 with
  gtk4-layer-shell. It changes nothing and exits 1 when a check fails.
- The feeds: each tool's `bar` command, a child of the daemon (the line).
- `layover-board`: the drawer. The daemon starts it, from next to its own
  binary, the first time one is asked for; it stays resident while hidden.
- Logs go to `$XDG_STATE_HOME/layover/daemon.log` and `board.log`
  (`$LAYOVER_STATE_DIR` overrides). `layover wear` keeps its last results in
  `wear.json` beside them.

| Crate | Role |
| --- | --- |
| [`bar-anchor`](https://github.com/NathanielInman/bar-anchor) | Anchoring and panel placement, shared by the waybar apps and pinned by tag in the root `Cargo.toml`. |
| `layover-core` | Config, durations, holds, the line's lamp readings, the state machine and its history, the lamp, the drawer's snapshot, the socket protocol, the waybar reader and the wear cache. No Wayland, no GPU, no UI. |
| `layover-hacks` | The renderer, the hacks, the Departure Board's font and cells, the rotation schedule and the wear test. |
| `layover` | The daemon, the saver, the CLI and the waybar module. |
| `layover-board` | The drawer: GTK4 on `gtk4-layer-shell`, overlay layer, namespace `layover`, keyboard exclusive while open. |

### Socket protocol

One JSON object per line. Requests: `{"cmd":"status"}`, `{"cmd":"watch"}`
(the reply stream stays open and sends a lamp on every change),
`{"cmd":"hold","secs":N}`, `{"cmd":"release"}`, `{"cmd":"now"}` (start the
saver now), `{"cmd":"stop"}`, `{"cmd":"toggle","anchor":A}` and
`{"cmd":"show","anchor":A}` (open the drawer from the bar, `A` being
bar-anchor's `Anchor` or absent to center it), `{"cmd":"board"}` and
`{"cmd":"line"}`. Replies
are a lamp `{"text","alt","class","tooltip"}` or `{"error"}`.

`line` keeps the connection open for the saver and sends
`{"rows":[{"what","from","status","tone"}],"cheap":bool}` now and on every
change.

`board` keeps the connection open for the drawer: a snapshot first, any
show waiting for a drawer that was starting, then a line per event:
`{"event":"snapshot","snapshot":{...}}` on every change, and
`{"event":"toggle"|"show","anchor":A}` or `{"event":"hide"}`. The snapshot
(`layover_core::board::Snapshot`) carries the lamp, the state and its
headline, the reason, the timings, the stations of the rail, the loosened
values with their reasons, whether a manual hold runs, the hack on screen
and the history, every string already worded.

## The drawer

`layover toggle` asks the compositor where the click was while the cursor
is still on the moon and sends the anchor; the drawer covers the monitor
with a transparent overlay surface, places the panel next to the bar at the
click (`bar_anchor::place`) and springs it open from there. A click outside
the panel or Escape closes it. Under sway and niri the anchor comes from
waybar's config, as in Tannoy; elsewhere, or with `--center`, it opens
centered. With `theme.from = "waybar"` it takes the bar's font and colors,
then `~/.config/layover/style.css` on top.

Three tabs:

- **Now**: the state in large type in its color (dim armed, amber held,
  frost saver), the reason, the idle line as configured (saver, lock, screens
  off, lock screen off; an off station says off), Start saver now and Hold 1h
  or Release, and every value looser than shipped with its reason.
- **Hacks**: each hack, whether it is in the rotation and whether it is on
  screen, and its wear numbers from `wear.json` with passes or fails. Measure
  runs `layover wear` in the background; Preview closes the drawer and runs
  `layover saver --hack <id> --for 20s`.
- **History**: the last 50 transitions, newest first, each with its local
  time and why: a station reached or held (once per hold, not every retry),
  the saver started, dismissed or ended, locked, screens off and on, holds
  and releases.

Keys: `1` to `3` pick a tab, `n` starts the saver, `h` holds for an hour,
`r` releases, Escape closes.

### The lamp

| Class | Shown | When |
| --- | --- | --- |
| `armed` | dim moon | waiting, nothing held |
| `held` | amber moon | a station was reached and held, or a manual hold runs |
| `saver` | frost moon | a hack is running |
| `dark` | dim moon | screens are off |
| `loose` | amber moon | config is looser than shipped (in the tooltip too) |
| `off` | nothing | the daemon is not running |

The text is the Nerd Font moon (md-weather-night, U+F0594) in every state
but `off`: waybar hides a custom module whose text is empty.
