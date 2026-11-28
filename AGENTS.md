# Layover

`docs/design.md` is the spec; the README is the tour. Read the spec section
for whatever you change, and read **Rule one** in it before touching a hack,
the care pass, the wear test or a default.

## Crates

- `layover-core`: config and its defaults, durations, the loosened-value
  check, the state machine (`state.rs`: events in, effects out), holds
  parsing (pactl streams, Hyprland clients), the line (`feeds.rs`: each
  tool's waybar lamp read into facts and a board row), the lamp, the drawer's
  snapshot, the socket protocol, the waybar reader and the wear cache.
  No Wayland, no GPU.
- `layover-hacks`: the renderer (hack pass, limiter, care pass), the hacks
  as WGSL in `src/hacks/`, the Departure Board's font and cells
  (`board.rs`), and the wear test. No Wayland.
- `layover`: one binary. The daemon (`daemon.rs`, `wayland.rs`, `feeds.rs`
  runs each tool's `bar` command), the saver
  (`saver.rs`: overlay surfaces through smithay-client-toolkit), the CLI and
  the waybar module.
- `bar-anchor` is no longer in this repo: it's the shared
  [bar-anchor](https://github.com/NathanielInman/bar-anchor) crate, pinned by tag in the root `Cargo.toml`.
  Change it there and move the tag; its `Anchor` JSON must stay
  identical across the apps.
- `layover-board`: the GTK4 layer-shell drawer. `anim.rs` and `stage.rs`
  came from Tannoy's board, `theme.rs` reads the bar's look. Check its
  layout headless with `GDK_BACKEND=broadway layover-board --shot out.png
  snapshot.json [now|hacks|hacks-list|sheet:<id>|history|menu]` (a snapshot is the `snapshot` field of
  a `{"cmd":"board"}` line).

## Build and test

Builds are heavy (wgpu). On Nate's desk run them under `lowprio`:
`lowprio cargo build --workspace --locked`, `lowprio cargo test --workspace
--locked`, `lowprio cargo clippy --workspace --all-targets -- -D warnings`.
CI also runs `cargo fmt --check` and `cargo deny check`.

The wear tests need a GPU adapter. CI installs Mesa's lavapipe. Set
`LAYOVER_SKIP_GPU_TESTS=1` only where no adapter exists; never in CI.

## Isolation

The desk you work on may run an installed Layover. Point a dev build
elsewhere with `LAYOVER_RUNTIME_DIR`, `LAYOVER_STATE_DIR`,
`LAYOVER_CONFIG_DIR` and `LAYOVER_CACHE_DIR`. `layover saver --hack <id>
--for 20s` shows one hack and exits without touching the daemon.

## Rules

- Rule one is not a style preference. A hack that fails the wear test does
  not ship, and the shipped budget only changes in a commit that explains why.
- New config keys go in `config.rs` defaults, `packaging/examples/config.toml`
  (with the reason and, for a protective value, the warning) and the spec. A
  test fails when the example and the defaults disagree.
- Hands off other programs: Layover reads Hyprland and pactl and never changes
  their state. The only things it sends are output power, the user's lock
  command and the user's own commands.
- The daemon never blocks on the saver or the lock: both are child processes.

## The line's privacy rule

A Departure Board row carries states and counts only, in Layover's own
words. Never copy free text (titles, songs, meeting names, secret names,
task text) from a lamp into a row; `feeds::tests::rows_never_copy_titles`
checks recorded lamps. Fixtures keep personal text replaced.

## When behavior changes

Update in the same commit: `docs/design.md` for a new key, station, hold,
socket message or rule; the README for anything a new user meets; and
`docs/assets/hero.py` when the lamp, a hack or the wear numbers it shows
change, then run `python3 docs/assets/hero.py` to rewrite `hero.svg` (never
edit the SVG by hand).

Commits are conventional, scoped by area: `core`, `state`, `holds`, `hacks`,
`wear`, `feeds`, `saver`, `daemon`, `cli`, `anchor`, `board`, `docs`, `ci`.

## Platforms

The suite targets Linux, Windows and macOS. `platforms` in
`docs/assets/suite.toml` lists where this app builds today, and `planned`
what a port still owes; CI and the pre-push hook hold it to `platforms`.

- Turn the hook on once per clone: `git config core.hooksPath .githooks`.
  Before a push it runs clippy for every platform listed (needs
  `rustup target add x86_64-pc-windows-gnu aarch64-apple-darwin` and, for
  crates with C code, `mingw-w64-gcc`). A failure there is a broken build on
  that platform: fix it, don't push past it with `--no-verify`.
- Code for one platform goes behind `#[cfg(...)]`, helpers included: a
  function only Linux calls is dead code on Windows, and `-D warnings` fails
  the build there.
- A test that needs something one platform has (a Linux-only binary, Unix
  socket behavior, a POSIX shell, a path layout) is gated with `#[cfg(...)]`
  or skips elsewhere.
