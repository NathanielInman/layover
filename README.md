<p align="center">
  <img src="docs/assets/mark.svg" width="46" alt="">
</p>

<h1 align="center">Layover</h1>

<p align="center">
  <img src="docs/assets/hero.svg" width="100%" alt="A floating waybar of frosted pills over a desktop with a terminal, where layover wear lists every hack passing rule one: Night Mail, Frost Aurora, Signal Lamps, Starfield, Menger Vault, Quasi Lattice, Ripple Tank, Moire Loom, Julia Filigree, Prism Barrel, Helix Tunnel, Pulsar Ridge and the Departure Board with their average level, longest lit dwell and hottest area. Layover&#x27;s lamp in the bar is a dim moon. A click on it springs the drawer out: the Now tab says Armed with the idle line, saver at 15m, lock with the dark, screens off at 1h, and buttons to start the saver or hold; the Hacks tab lists the thirteen hacks with the same wear numbers, each passing and in the rotation with a Preview button; the History tab lists what the line did and why. A click outside closes it. The desk goes quiet, the clock jumps from 14:28 to 14:43, and the saver fades in over the whole screen, bar included: a dim mail train with lit windows crosses dark hills while the moon climbs across a field of drifting stars and signal lamps scroll past. It hands off through black to Signal Lamps, soft red, green, amber and frost lamps drifting out of focus. The mouse moves and the saver is gone at once. In the terminal layover hold 1h turns the lamp amber, its tooltip says held by you for 1h more, and layover release turns it dim again.">
</p>

<p align="center">
  <b>A screensaver for Wayland that looks after your monitor.</b><br>
  GPU hacks on overlay layer surfaces, an idle line that runs saver, lock and dark,<br>
  and a lamp in your bar that says why the screen did what it did.
</p>

<p align="center">
  <a href="https://github.com/NathanielInman/layover/actions/workflows/ci.yml"><img src="https://github.com/NathanielInman/layover/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/status-early%20(0.1)-ebcb8b" alt="Early, version 0.1">
  <img src="https://img.shields.io/badge/burn--in-tested%20in%20CI-88c0d0" alt="Burn-in tested in CI">
  <img src="https://img.shields.io/badge/Arch%20%2B%20Hyprland%20first-Linux%20%C2%B7%20Wayland-a3be8c" alt="Arch and Hyprland first; Linux with Wayland">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-b48ead" alt="MIT license"></a>
</p>

A layover is the rest a train crew takes between runs. Layover is what your
desk does between yours. [Switchyard](https://github.com/NathanielInman/switchyard)
dispatches your work, [Roundhouse](https://github.com/NathanielInman/roundhouse)
says whether the machine is fit to run it, and Layover looks after the screen
while you're away.

Layover is early (0.1). It runs on Hyprland; sway and niri should work but
are untested. `docs/design.md` is the spec.

## Why

xscreensaver is an X11 program. Under Wayland it can't tell when you're idle
and can't lock, so most Wayland desks run hypridle, a shell script and a
lock screen, and the screen just goes black. Layover brings the hacks back,
draws them with the GPU across every output as one picture (a Samsung G9
split into two outputs gets one 32:9 scene), and treats your panel like an
OLED it has to look after.

## Rule one

Every hack wears the panel evenly, gently and briefly.

1. **Nothing holds still.** A lit pixel changes within 20 seconds, and the
   whole frame slowly orbits.
2. **Dim by default.** No subpixel above 60%, and a limiter holds the
   frame's average under 12%.
3. **Share the load across subpixels.** Colors turn through the color wheel
   every 6 minutes so red, green and blue age together, and white is capped.
4. **Take turns, then rest.** Hacks hand off every 10 minutes, and the run
   ends with the screens off.
5. **Measured, not eyeballed.** Every hack passes a wear test in CI: an
   hour rendered headless, light added up per pixel, checked against the
   budget.
6. **Safe defaults, honest warnings.** You can change any limit. The shipped
   config says why each exists, and `layover check` and the lamp list every
   value you've loosened.

## The idle line

| After | What happens |
| --- | --- |
| 15 minutes idle | A hack starts. Any key, click or real pointer movement dismisses it. |
| 1 hour idle | The session locks (hyprlock) and the screens turn off. |

While a lock screen is up and the screens are on, they turn off after a
minute: a lock screen doesn't move. Both timings go down to 1 minute or off.

Some things hold the line: a window keeping the screen on (a video), an app
recording from a microphone (a call), Logbook on air, a meeting about to
start on Timetable (the saver only), and `layover hold`. Playing audio holds
only the dark, so music never leaves a still desktop on the panel: the saver
runs instead. Idle inhibitors from windows that hold one all the time (T3
Code's) are ignored.

## The line

Layover reads the other tools on the desk from the lamps they print for
waybar ([Timetable](https://github.com/NathanielInman/timetable),
[Switchyard](https://github.com/NathanielInman/switchyard), Waybill,
[Signal Box](https://github.com/NathanielInman/credential-broker),
[Roundhouse](https://github.com/NathanielInman/roundhouse),
[Tablet](https://github.com/NathanielInman/tablet),
[Logbook](https://github.com/NathanielInman/logbook),
[Tannoy](https://github.com/NathanielInman/tannoy)). Whichever are
installed:

- **Hold the saver.** Logbook on air holds everything; a meeting about to
  start holds the saver.
- **Cheap mode.** While Switchyard builds on its main line or Roundhouse
  warns about heat, the saver draws at half rate, half size and three
  quarters of the brightness, and says so on the lamp.
- **The Departure Board.** A hack you can read from across the room: a row
  per tool with its state ("MEETING IN 7M", "33 TASKS WAIT ON YOU", "AGENT
  ASKS FOR A KEY"). States and counts only: song titles, meeting names,
  secret names and task text never reach the screen.

`[feeds]` in the config names each tool's command, turns one off with `[]`,
and turns the holds and cheap mode off.

## Install

```sh
cargo build --release --locked
install -Dm755 target/release/layover target/release/layover-board -t ~/.local/bin/
```

It needs a Vulkan driver, `pactl` (for the audio and microphone holds),
GTK4 and `gtk4-layer-shell` (for the drawer) and a compositor with `ext-idle-notify-v1`, `wlr-layer-shell` and
`wlr-output-power-management`.

Start the daemon with your session, in place of hypridle. With systemd,
copy `packaging/systemd/layover.service` to `~/.config/systemd/user/`, set
`ExecStart=%h/.local/bin/layover daemon`, and run
`systemctl --user enable --now layover.service`. Or from Hyprland (0.55+,
Lua config):

```lua
hl.exec_cmd("~/.local/bin/layover daemon")
```

Then add the lamp to waybar from `packaging/examples/waybar-modules.jsonc`
and `packaging/examples/waybar-style.css`, and run `layover doctor`. It
checks the config, the daemon and `layover.service`, the three Wayland
protocols, the Vulkan adapter, `pactl`, Hyprland's socket, the lock command,
the feeds, the waybar module and the drawer with its libraries, and exits 1
when something is broken.

## Locking, and a YubiKey on the lock screen

Layover runs your lock command (`hyprlock` by default) as the screens go off,
and never draws a password prompt itself. To unlock hyprlock with a touch of
a YubiKey instead of (or as well as) your password, use `pam_u2f`. A
suggestion, not tested on every setup:

```sh
sudo pacman -S pam-u2f
mkdir -p ~/.config/Yubico
pamu2fcfg > ~/.config/Yubico/u2f_keys      # touch the key when it blinks
```

Then add one line to `/etc/pam.d/hyprlock`, above `auth include login`:

```
auth sufficient pam_u2f.so cue
```

`sufficient` lets the key alone unlock; `required` asks for the key and your
password. Keep a root shell open while you try it, lock with your usual
bind, press Enter on the empty field and touch the key when the cue shows.

## The lamp

| Lamp | Means |
| --- | --- |
| dim moon | armed, waiting |
| amber moon | held (the tooltip says by what), or your config is looser than shipped |
| frost moon | a hack is running |
| none | the daemon isn't running |

Click it and the drawer springs out of the moon; middle-click starts the
saver now, right-click holds for an hour.

## The drawer

Three tabs. **Now** shows the state and why, the idle line as you configured
it, Start saver now and Hold or Release, and anything looser than shipped
with what it risks. **Hacks** shows every hack with its wear numbers from
the last `layover wear`, whether it is in the rotation, a Measure button and
a 20 second Preview of each. **History** shows the last 50 things the line
did, with the time and why. Keys: `1` to `3`, `n` start, `h` hold, `r`
release, Escape. It takes your waybar's font and colors.

## Commands

```
layover daemon                 run the idle line
layover bar                    the waybar module
layover toggle [--center]      open or close the drawer from the clicked moon
layover status                 what the idle line is doing, and why
layover now | stop             start or stop the saver
layover hold 1h | release      hold the line, or end the hold
layover check                  check the config and list loosened values
layover doctor                 check the setup (exits 1 when something is broken)
layover hacks                  list the hacks
layover saver --hack starfield --for 20s
                               show a hack now, without the daemon
layover wear [<id>...]         run the wear test against your config and write heat maps
```

## Hacks

| Hack | |
| --- | --- |
| `night-mail` | A mail train crosses dark hills while the moon climbs across the sky. |
| `frost-aurora` | Frost, green and purple curtains over black mountains. |
| `signal-lamps` | Out-of-focus yard lamps drifting in the dark, a few of them blinking. |
| `starfield` | The classic flight through the stars, rebuilt for 32:9. |
| `menger-vault` | An endless vaulted Menger sponge curving through the dark (after Menger by Jamie Zawinski). |
| `quasi-lattice` | Shifting aperiodic crystal tilings from interfering plane waves (after Quasicrystal by Jamie Zawinski). |
| `ripple-tank` | Rings from drifting sources cross into shifting interference bands (after Interference by Hannu Mallat). |
| `moire-loom` | Overlapping optical rulings weave shifting watered-silk interference bands (after Moire and Moire2 by Jamie Zawinski). |
| `julia-filigree` | Luminous Julia-set filaments morphing across the dark (after Julia by Sean McCullough). |
| `prism-barrel` | Stained-glass shards and sweeping arcs tumbling through shifting mirror chambers (after Kaleidescope by Ron Tapia). |
| `helix-tunnel` | Curving helical ribs, vortex bands and rushing starlight (after Atunnel by Roman Podobedov, Timetunnel by Sean Brennan and Wormhole by Jon Rafkind). |
| `pulsar-ridge` | Hidden-line pulsar ridgelines scrolling across the dark (after Unknown Pleasures by Jamie Zawinski). |
| `departure-board` | Split-flap rows from the other tools on the desk. Text-heavy, so it drifts, flaps and hands off after 3 minutes. |

A hack is one WGSL function, `hack(p, t) -> color`, in
`crates/layover-hacks/src/hacks/`. The care pass applies rule one after it,
and the wear test decides whether it ships.

## Config

`~/.config/layover/layover.toml`. Every key, with its reason and warning, is
in [`packaging/examples/config.toml`](packaging/examples/config.toml). A
missing file means the shipped defaults.

## License

MIT
