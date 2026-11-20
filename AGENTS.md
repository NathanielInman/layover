# Layover

`docs/design.md` is the spec; the README is the tour. Read the spec section
for whatever you change, and read **Rule one** in it before touching a hack,
the care pass, the wear test or a default.

## Crates

- `layover-core`: config and its defaults, durations, the loosened-value
  check, the state machine (`state.rs`: events in, effects out), holds
  parsing (ALSA status, Hyprland clients), the lamp and the socket protocol.
  No Wayland, no GPU.
- `layover-hacks`: the renderer (hack pass, limiter, care pass), the hacks
  as WGSL in `src/hacks/`, and the wear test. No Wayland.
- `layover`: one binary. The daemon (`daemon.rs`, `wayland.rs`), the saver
  (`saver.rs`: overlay surfaces through smithay-client-toolkit), the CLI and
  the waybar module.

## Build and test

Builds are heavy (wgpu). On Nate's desk run them under `lowprio`:
`lowprio cargo build --workspace --locked`, `lowprio cargo test --workspace
--locked`, `lowprio cargo clippy --workspace --all-targets -- -D warnings`.
CI also runs `cargo fmt --check` and `cargo deny check`.

The wear tests need a GPU adapter. CI installs Mesa's lavapipe. Set
`LAYOVER_SKIP_GPU_TESTS=1` only where no adapter exists; never in CI.

## Isolation

The desk you work on may run an installed Layover. Point a dev build
elsewhere with `LAYOVER_RUNTIME_DIR`, `LAYOVER_STATE_DIR` and
`LAYOVER_CONFIG_DIR`. `layover saver --hack <id> --for 20s` shows one hack and
exits without touching the daemon.

## Rules

- Rule one is not a style preference. A hack that fails the wear test does
  not ship, and the shipped budget only changes in a commit that explains why.
- New config keys go in `config.rs` defaults, `packaging/examples/config.toml`
  (with the reason and, for a protective value, the warning) and the spec. A
  test fails when the example and the defaults disagree.
- Hands off other programs: Layover reads Hyprland and ALSA and never changes
  their state. The only things it sends are output power, the user's lock
  command and the user's own commands.
- The daemon never blocks on the saver or the lock: both are child processes.

## When behavior changes

Update in the same commit: `docs/design.md` for a new key, station, hold,
socket message or rule; the README for anything a new user meets.

Commits are conventional, scoped by area: `core`, `state`, `holds`, `hacks`,
`wear`, `saver`, `daemon`, `cli`, `docs`, `ci`.
