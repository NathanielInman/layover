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
| Microphone | an ALSA capture stream in state `RUNNING` | saver, lock, dark |
| Audio | an ALSA playback stream in state `RUNNING` | `holds.audio`: `"dark"` (default), `"all"` or `"off"` |
| Manual | `layover hold <duration>` | saver, lock, dark |

Audio holds only the dark by default: a static desktop while music plays is
the worst case for a panel, and a hack under the care rules is not. A held
station is checked again every 60 seconds while the desk stays idle.

ALSA status comes from `/proc/asound/card*/pcm*/sub*/status`. PipeWire
suspends idle devices, so `RUNNING` means sound is going to hardware. Bluetooth
audio does not show there; that is a known gap.

### The state machine

`layover-core/src/state.rs` is pure: events in (a station reached with the
holds at that moment, input resumed, a command, the saver exiting, a tick),
effects out (start or stop the saver, run the lock, power outputs off or on,
publish the lamp). Every rule about what the daemon does lives there with a
test.

## Hacks

A hack is a WGSL fragment function in `layover-hacks/src/hacks/`:

```wgsl
fn hack(p: vec2<f32>, t: f32) -> vec3<f32>
```

`p` is the position on the canvas in canvas heights: `y` runs from 0 at the
bottom to 1 at the top and `x` from 0 to the canvas aspect. The canvas is the
bounding box of every output, so a G9 split into two outputs gets one 32:9
picture. `t` is seconds since the saver started. The prelude
(`hacks/prelude.wgsl`) has the uniforms, hashes and noise.

Each frame:

1. The hack pass draws the whole canvas into one offscreen texture at
   `power.render_scale`, with the orbit offset added to every position.
2. The limiter pass measures the average level on a sparse grid and eases a
   gain toward `care.max_average`.
3. A care pass per output samples that output's part of the texture and
   applies, in order: hue turn (if the hack allows it), drive scale,
   limiter gain, white cap and fade.

Hacks hand off with a fade through black. Text-heavy hacks declare it and use
`care.text_rotate`.

### The wear test

`layover-hacks/src/wear.rs` renders a hack headless at 256 × 72 for a
simulated hour, one frame per second, through the same care pass, and
measures:

| Metric | Budget |
| --- | --- |
| Average picture level | `care.max_average` |
| Longest lit dwell: a pixel above 25% that changed by less than 3% | `care.max_dwell` |
| Hottest area: the highest per-pixel average level | `care.max_hot_spot` |
| Channel share: each of red, green and blue as a share of all light | 40% |
| Peak drive | `care.max_drive` |

`cargo test` runs it for every hack against the shipped budget (it needs a
GPU adapter; CI uses Mesa's lavapipe). `layover wear <hack>` runs it against
your config and writes a heat map PNG.

## Config

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
- Logs go to `$XDG_STATE_HOME/layover/daemon.log` (`$LAYOVER_STATE_DIR`
  overrides).

### Socket protocol

One JSON object per line. Requests: `{"cmd":"status"}`, `{"cmd":"watch"}`
(the reply stream stays open and sends a lamp on every change),
`{"cmd":"hold","secs":N}`, `{"cmd":"release"}`, `{"cmd":"now"}` (start the
saver now) and `{"cmd":"stop"}`. Replies are a lamp
`{"text","alt","class","tooltip"}` or `{"error"}`.

### The lamp

| Class | Shown | When |
| --- | --- | --- |
| `armed` | dim dot | waiting, nothing held |
| `held` | amber dot | a station was reached and held, or a manual hold runs |
| `saver` | frost dot | a hack is running |
| `dark` | dim dot | screens are off |
| `loose` | amber ring | config is looser than shipped (in the tooltip too) |
| `off` | nothing | the daemon is not running |
