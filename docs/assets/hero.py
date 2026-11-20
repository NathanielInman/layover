#!/usr/bin/env python3
"""Writes docs/assets/hero.svg: the README's animated hero.

An 18 second loop on the same desktop as Roundhouse's, Switchyard's,
Tannoy's and Tablet's heroes, under the floating Platform bar. A terminal
shows `layover wear`: every hack passing rule one, with the numbers the
wear test really measures. The desk goes quiet, the clock jumps fifteen
minutes and the saver fades in over everything, the bar too: Night Mail's
train crosses the hills under a moon that climbs across the sky, then the
saver hands off through black to Signal Lamps. A nudge of the mouse ends it
at once. `layover hold 1h` turns Layover's lamp amber, and its tooltip says
why; `layover release` turns it dim again.

The hacks here are sketches of the WGSL ones, kept as dim as the care pass
keeps the real ones. Pure CSS animation inside the SVG, so GitHub plays it
in an <img>. With reduced motion it is a still of Night Mail.

    python3 docs/assets/hero.py
"""

import math
import random
from pathlib import Path

W, H = 1200, 660
T = 18  # loop seconds

# Nord, matching the Platform waybar and the siblings' heroes.
BG0, BG1 = "#14171c", "#0d0f12"
PILL, PILL_LINE, PILL_ON = "#24262a", "#3a404d", "#3c4651"
BAR_FG, BRIGHT, BAR_DIM = "#c5c8c6", "#d8dee9", "#616e88"
PANEL, PANEL_LINE = "#1e2024", "#41464e"
FG, DIM = "#c5c8c6", "#7c838e"
FROST, GO, AMBER, RED, PURPLE = "#88c0d0", "#a3be8c", "#ebcb8b", "#bf616a", "#b48ead"
FONT = "JetBrains Mono, DejaVu Sans Mono, Menlo, Consolas, monospace"

# The README's alt text says the same.
ALT = (
    "A floating waybar of frosted pills over a desktop with a terminal, where layover wear lists every hack "
    "passing rule one: Night Mail, Frost Aurora, Signal Lamps and Starfield with their average level, longest "
    "lit dwell and hottest area. Layover's lamp in the bar is a dim moon. The desk goes quiet, the clock jumps "
    "from 14:28 to 14:43, and the saver fades in over the whole screen, bar included: a dim mail train with lit "
    "windows crosses dark hills while the moon climbs across a field of drifting stars and signal lamps scroll "
    "past. It hands off through black to Signal Lamps, soft red, green, amber and frost lamps drifting out of "
    "focus. The mouse moves and the saver is gone at once. In the terminal layover hold 1h turns the lamp "
    "amber, its tooltip says held by you for 1h more, and layover release turns it dim again."
)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def tx(x, y, s, size=13, fill=FG, weight=400, anchor="start", attrs=""):
    """A <text> element as a string."""
    attrs = f" {attrs}" if attrs else ""
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}"{attrs}>{esc(s)}</text>'


def g_bell(cx, cy, c):
    return (f'<path d="M{cx - 5.5},{cy + 3.5} L{cx - 5.5},{cy - 1} Q{cx - 5.5},{cy - 6.5} {cx},{cy - 6.5} Q{cx + 5.5},{cy - 6.5} {cx + 5.5},{cy - 1} L{cx + 5.5},{cy + 3.5} L{cx + 7},{cy + 5} L{cx - 7},{cy + 5} Z" fill="{c}"/>'
            f'<circle cx="{cx}" cy="{cy + 7}" r="1.8" fill="{c}"/>')


def g_speaker(cx, cy, c):
    return (f'<path d="M{cx - 7},{cy - 2.5} L{cx - 4},{cy - 2.5} L{cx},{cy - 6} L{cx},{cy + 6} L{cx - 4},{cy + 2.5} L{cx - 7},{cy + 2.5} Z" fill="{c}"/>'
            f'<path d="M{cx + 3},{cy - 3} Q{cx + 5.5},{cy} {cx + 3},{cy + 3} M{cx + 5.5},{cy - 5.5} Q{cx + 10},{cy} {cx + 5.5},{cy + 5.5}" fill="none" stroke="{c}" stroke-width="1.5" stroke-linecap="round"/>')


# ---------------------------------------------------------------- animation

# The story, in seconds.
QUIET = 2.8  # the clock jumps: fifteen minutes idle
SAVER = 3.0  # the saver starts fading in (1.5 s, as the real one does)
HANDOFF = 8.6  # Night Mail fades out
LAMPS_IN = 9.2  # Signal Lamps fades in
WAKE = 13.4  # the mouse moves: the saver is gone
HOLD = 14.2  # `layover hold 1h`
RELEASE = 16.4  # `layover release`
RESET = 17.4

out, kfs = [], []


def add(s):
    out.append(s)


def pct(sec):
    return f"{max(0.0, min(100.0, sec / T * 100)):.2f}%"


def frames(pts):
    """A keyframe set from (seconds, declarations) points; returns its name."""
    name = f"k{len(kfs)}"
    rows = " ".join(f"{pct(t)} {{ {d}; }}" for t, d in pts)
    kfs.append(f"@keyframes {name} {{ {rows} }}")
    return name


def anim(prop, pts):
    return frames([(t, f"{prop}: {v}") for t, v in pts])


def fade(spans, ramp=0.16, out_ramp=None):
    """Opacity keyframes visible during each (start, end) span."""
    out_ramp = ramp if out_ramp is None else out_ramp
    pts = []
    for s, e in spans:
        if s <= 0:
            pts.append((0, 1))
        else:
            pts += [(0, 0)] if not pts else []
            pts += [(s, 0), (s + ramp, 1)]
        if e >= T:
            pts.append((T, 1))
        else:
            pts += [(e, 1), (e + out_ramp, 0)]
    if pts[-1][0] < T:
        pts.append((T, 0))
    return anim("opacity", pts)


def style(*names, extra=""):
    return f'class="a" style="animation-name:{",".join(names)};{extra}"'


def group(name, shown=True, extra=""):
    """A group that fades by `name`; `shown` is its state in the still."""
    add(f'<g {style(name, extra=extra)} opacity="{1 if shown else 0}">')


def slide(spans_pts, still):
    """A group translated through (seconds, x, y) points."""
    k = anim("transform", [(t, f"translate({x:.1f}px, {y:.1f}px)") for t, x, y in spans_pts])
    add(f'<g {style(k, extra=f"transform:translate({still[0]:.1f}px, {still[1]:.1f}px)")}>')


# ---------------------------------------------------------------- scene

css = f"""
text {{ white-space: pre; }}
.a {{ animation-duration: {T}s; animation-iteration-count: infinite; animation-timing-function: linear; animation-fill-mode: both; }}
.tw1 {{ animation: tw 2.3s ease-in-out infinite; }}
.tw2 {{ animation: tw 3.1s ease-in-out infinite .8s; }}
.tw3 {{ animation: tw 4.2s ease-in-out infinite 1.6s; }}
.blink {{ animation: blink 1.4s steps(1) infinite; }}
@keyframes tw {{ 0%, 100% {{ opacity: .85; }} 50% {{ opacity: .3; }} }}
@keyframes blink {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: .15; }} }}
@media (prefers-reduced-motion: reduce) {{
  .a, .tw1, .tw2, .tw3, .blink {{ animation: none !important; }}
  #cursor, .ripple {{ display: none; }}
}}
"""


def song_defs():
    """Tannoy's song cover, for the media pill."""
    lanterns = ""
    for x, y, s in [(26, 40, 1.0), (54, 28, 1.25), (78, 46, 0.85)]:
        lanterns += (f'<line x1="{x}" y1="0" x2="{x}" y2="{y - 9 * s:.1f}" stroke="#2e2235" stroke-width="1.2"/>'
                     f'<circle cx="{x}" cy="{y}" r="{18 * s:.1f}" fill="url(#glow)"/>'
                     f'<rect x="{x - 6 * s:.1f}" y="{y - 9 * s:.1f}" width="{12 * s:.1f}" height="{18 * s:.1f}" rx="{5 * s:.1f}" fill="#ebcb8b"/>')
    return ('<linearGradient id="dusk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3b2b4a"/><stop offset=".7" stop-color="#b8706a"/><stop offset="1" stop-color="#d08770"/></linearGradient>'
            '<radialGradient id="glow"><stop offset="0" stop-color="#ebcb8b" stop-opacity=".55"/><stop offset="1" stop-color="#ebcb8b" stop-opacity="0"/></radialGradient>'
            '<clipPath id="art"><rect width="100" height="100" rx="7"/></clipPath>'
            f'<symbol id="song" viewBox="0 0 100 100"><g clip-path="url(#art)"><rect width="100" height="100" fill="url(#dusk)"/>{lanterns}'
            '<path d="M0,74 Q22,64 44,72 T100,68 V100 H0 Z" fill="#2e2235"/></g></symbol>')


# Signal Lamps' soft discs: a level in the middle, a faint rim, nothing past it.
LAMP_TINTS = {"r": "#bf616a", "g": "#a3be8c", "a": "#ebcb8b", "f": "#88c0d0"}


def lamp_defs():
    s = ""
    for k, c in LAMP_TINTS.items():
        s += (f'<radialGradient id="lamp{k}"><stop offset="0" stop-color="{c}" stop-opacity=".2"/>'
              f'<stop offset=".78" stop-color="{c}" stop-opacity=".16"/><stop offset=".9" stop-color="{c}" stop-opacity=".24"/>'
              f'<stop offset="1" stop-color="{c}" stop-opacity="0"/></radialGradient>')
    return s


add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="{FONT}" xml:space="preserve" role="img" aria-label="{esc(ALT)}">')
STYLE_AT = len(out)
add("")  # the <style> goes here once every keyframe exists
add(f"""<defs>
<linearGradient id="wall" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{BG0}"/><stop offset="1" stop-color="{BG1}"/></linearGradient>
<radialGradient id="haze1" cx=".85" cy="0" r=".75"><stop offset="0" stop-color="{FROST}" stop-opacity=".13"/><stop offset="1" stop-color="{FROST}" stop-opacity="0"/></radialGradient>
<radialGradient id="haze2" cx=".05" cy="1" r=".6"><stop offset="0" stop-color="{PURPLE}" stop-opacity=".09"/><stop offset="1" stop-color="{PURPLE}" stop-opacity="0"/></radialGradient>
<linearGradient id="night" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#05070c"/><stop offset=".62" stop-color="#0c1220"/><stop offset="1" stop-color="#090c14"/></linearGradient>
<radialGradient id="moonglow"><stop offset="0" stop-color="#9aa3b4" stop-opacity=".16"/><stop offset="1" stop-color="#9aa3b4" stop-opacity="0"/></radialGradient>
<radialGradient id="sigr"><stop offset="0" stop-color="#bf616a" stop-opacity=".9"/><stop offset=".25" stop-color="#bf616a" stop-opacity=".3"/><stop offset="1" stop-color="#bf616a" stop-opacity="0"/></radialGradient>
<radialGradient id="sigg"><stop offset="0" stop-color="#a3be8c" stop-opacity=".9"/><stop offset=".25" stop-color="#a3be8c" stop-opacity=".3"/><stop offset="1" stop-color="#a3be8c" stop-opacity="0"/></radialGradient>
<linearGradient id="beam" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#c9ccc2" stop-opacity=".22"/><stop offset="1" stop-color="#c9ccc2" stop-opacity="0"/></linearGradient>
<mask id="crescent"><rect x="-40" y="-40" width="80" height="80" fill="#fff"/><circle cx="11" cy="-5" r="25" fill="#000"/></mask>
{lamp_defs()}
{song_defs()}
<filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity=".65"/></filter>
<clipPath id="screen"><rect width="{W}" height="{H}" rx="18"/></clipPath>
</defs>""")
add('<g clip-path="url(#screen)">')
add(f'<rect width="{W}" height="{H}" fill="url(#wall)"/><rect width="{W}" height="{H}" fill="url(#haze1)"/><rect width="{W}" height="{H}" fill="url(#haze2)"/>')


def window(x, y, w, h, title=""):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="#1a1d22" stroke="#2a2e35"/>')
    add(f'<rect x="{x}" y="{y}" width="{w}" height="30" rx="12" fill="#1f2328"/>')
    for k, c in enumerate([RED, AMBER, GO]):
        add(f'<circle cx="{x + 18 + k * 16}" cy="{y + 15}" r="5" fill="{c}" fill-opacity=".55"/>')
    if title:
        add(tx(x + w / 2, y + 19, title, 11, DIM, anchor="middle"))


# The terminal: the wear test's real numbers from `cargo test`.
TX_, TY_, TW_, TH_ = 34, 36, 640, 360
window(TX_, TY_, TW_, TH_, "zsh · ~/Sites/layover")
TL = TX_ + 18


def term(y, s, c=FG, spans=None, weight=400):
    if spans is None:
        add(tx(TL, y, s, 12.5, c, weight))
    else:
        group(fade(spans, 0.05), any(a <= SAVER + 2 <= b for a, b in spans))
        add(tx(TL, y, s, 12.5, c, weight))
        add("</g>")


ty = TY_ + 58
term(ty, "$ layover wear", FROST)
WEAR = [
    ("night-mail", "2.8%", " 8s", " 5.7%"),
    ("frost-aurora", "6.6%", "13s", "14.4%"),
    ("signal-lamps", "1.5%", " 9s", " 1.9%"),
    ("starfield", "0.1%", " 2s", " 0.3%"),
]
for i, (hack, avg, dwell, hot) in enumerate(WEAR):
    y = ty + 24 + i * 21
    add(tx(TL, y, f"{hack:<13} average {avg:>4}  dwell {dwell}  hottest {hot:>5}", 12.5, FG))
    add(tx(TL + 54 * 7.5, y, "passes", 12.5, GO, 700))
term(ty + 24 + 4 * 21 + 4, "budget: average 12%, dwell 20s, hottest 25%, each color 40%", DIM)
term(ty + 148, "$ layover hold 1h", FROST, [(HOLD, RESET)])
term(ty + 169, "Held by you for 1h more. `layover release` ends it.", DIM, [(HOLD + 0.25, RESET)])
term(ty + 194, "$ layover release", FROST, [(RELEASE, RESET)])
term(ty + 215, "Saver after 15m · lock with the dark · screens off after 1h", DIM, [(RELEASE + 0.25, RESET)])

# ---------------------------------------------------------------- the bar
# packages/waybar in dot-files: a floating bar 34 px high, 6 px off the
# edges, 6 px between pills. Modules pad 8 px a side inside a group's 4.

BAR_Y, BAR_H = 620, 34
MID = BAR_Y + 21.5  # text baseline
CY = BAR_Y + BAR_H / 2
BAR_SIZE, CW = 13, 7.8  # bar font size and its advance
GW = 11  # a Nerd Font glyph's width in the bar


def pill(x, w, fill=PILL):
    add(f'<rect x="{x:.1f}" y="{BAR_Y + 0.5}" width="{w:.1f}" height="{BAR_H - 1}" rx="10" fill="{fill}" stroke="{PILL_LINE}"/>')


# Left: workspaces and the window title.
x = 6
ws = [("1", True), ("2", False), ("3", False)]
ws_w = 4 + len(ws) * (8 + CW + 8 + 2) + 4
pill(x, ws_w)
bx = x + 4
for num, active in ws:
    w = 8 + CW + 8
    bx += 1
    if active:
        add(f'<rect x="{bx:.1f}" y="{BAR_Y + 4}" width="{w:.1f}" height="{BAR_H - 8}" rx="7" fill="{PILL_ON}"/>')
    add(tx(bx + 8, MID, num, BAR_SIZE, BRIGHT if active else BAR_FG, attrs='fill-opacity=".7"'))
    bx += w + 1
x += ws_w + 6
TITLE = "zsh · layover"
title_w = 12 + len(TITLE) * CW + 12
pill(x, title_w)
add(tx(x + 12, MID, TITLE, BAR_SIZE, BRIGHT))
LEFT_END = x + title_w

# Right, packed from the edge: the tray, the clock, the desk, audio, the
# lamps, then the media pill.
x = W - 6
tray_w = 10 + 3 * 14 + 2 * 8 + 10
x -= tray_w
pill(x, tray_w)
for k, c in enumerate(["#81a1c1", PURPLE, "#5e81ac"]):
    add(f'<rect x="{x + 10 + k * 22}" y="{CY - 7}" width="14" height="14" rx="4" fill="{c}" fill-opacity=".8"/>')
CLOCKS = [("Fri Nov 20  14:28", [(0, QUIET)]), ("Fri Nov 20  14:43", [(QUIET, WAKE)]), ("Fri Nov 20  14:51", [(WAKE, T)])]
clock_w = 12 + len(CLOCKS[0][0]) * CW + 12
x -= 6 + clock_w
pill(x, clock_w)
for s, spans in CLOCKS:
    group(fade(spans, 0.01, 0.01), any(a <= SAVER + 2 <= b for a, b in spans))
    add(tx(x + 12, MID, s, BAR_SIZE, PURPLE))
    add("</g>")
desk_w = 4 + (16 + GW) + (16 + 8) + 4
x -= 6 + desk_w
pill(x, desk_w)
mx = x + 4 + 8 + GW / 2
add(f'<g fill="none" stroke="{BAR_DIM}" stroke-width="1.5" stroke-linecap="round"><rect x="{mx - 2.8}" y="{CY - 7.5}" width="5.6" height="9.5" rx="2.8"/><path d="M{mx - 5.5},{CY - 1} a5.5,5.5 0 0 0 11,0 M{mx},{CY + 4.5} v3"/></g>')
hx = x + 4 + 16 + GW + 8 + 4
add(f'<path d="M{hx + 2},{CY - 5} l-5,5 l5,5" fill="none" stroke="{BAR_DIM}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>')
vol_w = 16 + GW + CW + 3 * CW
audio_w = 4 + vol_w + 4
x -= 6 + audio_w
pill(x, audio_w)
add(g_speaker(x + 4 + 8 + 7, CY, FROST))
add(tx(x + 4 + 8 + GW + CW, MID, "35%", BAR_SIZE, FROST))

# The lamps: Roundhouse's green dot, Switchyard's board, Waybill's ring,
# Layover's moon (dim when armed, amber when held), the do-not-disturb bell.
LAMP = 16 + GW
lamps_w = 4 + 5 * LAMP + 4
lx = x - 6 - lamps_w
pill(lx, lamps_w)
cx = [lx + 4 + LAMP / 2 + i * LAMP for i in range(5)]
add(f'<circle cx="{cx[0]}" cy="{CY}" r="5.5" fill="{GO}"/>')
add(f'<rect x="{cx[1] - 5}" y="{CY - 9}" width="10" height="18" rx="4" fill="none" stroke="{FROST}" stroke-width="1.4"/>')
for dy in (-5, 0, 5):
    add(f'<circle cx="{cx[1]}" cy="{CY + dy}" r="1.8" fill="{FROST}"/>')
add(f'<circle cx="{cx[2]}" cy="{CY}" r="5.5" fill="none" stroke="{BAR_DIM}" stroke-width="1.6"/>')
LAYOVER_X = cx[3]


def g_moon(cx, cy, c):
    """The lamp's glyph, md-weather-night: a crescent."""
    return (f'<path d="M{cx + 1.5},{cy - 7} A7,7 0 1 0 {cx + 6.5},{cy + 3.2} A5.6,5.6 0 1 1 {cx + 1.5},{cy - 7} Z" fill="{c}"/>')


add(g_moon(LAYOVER_X, CY, BAR_DIM))
group(fade([(HOLD + 0.35, RELEASE + 0.35)], 0.01, 0.01), False)
add(f'<rect x="{LAYOVER_X - 9}" y="{CY - 10}" width="18" height="20" fill="{PILL}"/>')
add(g_moon(LAYOVER_X, CY, AMBER))
add("</g>")
add(g_bell(cx[4], CY, BAR_DIM))

SONG_BAR = "Marlow Fen · Paper Lanterns"
w = 10 + 18 + 8 + len(SONG_BAR) * CW + 12
px = lx - 6 - w
pill(px, w)
add(f'<use href="#song" x="{px + 10:.1f}" y="{CY - 9}" width="18" height="18"/>')
add(tx(px + 36, MID, SONG_BAR, BAR_SIZE, AMBER))
assert px - 6 >= LEFT_END, f"the bar overflows by {LEFT_END - px + 6:.0f}px"

# The lamp's tooltip while held.
TIP = ["Held by you for 1h more. `layover release` ends it.", "Saver after 15m · lock with the dark · screens off after 1h"]
tip_w = 24 + max(len(s) for s in TIP) * 7.2
tip_h = 20 + len(TIP) * 19
tip_x = min(LAYOVER_X - tip_w / 2, W - 10 - tip_w)
tip_y = BAR_Y - 10 - tip_h
group(fade([(HOLD + 0.8, RELEASE)], 0.12, 0.12), False)
add(f'<rect x="{tip_x:.1f}" y="{tip_y}" width="{tip_w:.1f}" height="{tip_h}" rx="10" fill="{PANEL}" stroke="{PANEL_LINE}" filter="url(#shadow)"/>')
for i, s in enumerate(TIP):
    add(tx(tip_x + 12, tip_y + 25 + i * 19, s, 12, FG if i == 0 else DIM))
add("</g>")

# ---------------------------------------------------------------- the saver
# An overlay surface: it covers the bar too. Everything in it is dim.

rng = random.Random(452)
group(fade([(SAVER, WAKE)], 1.5, 0.04), True)
add(f'<rect width="{W}" height="{H}" fill="#000"/>')
add("</g>")

# Night Mail.
group(fade([(SAVER, HANDOFF)], 1.5, 0.45), True)
add(f'<rect width="{W}" height="{H}" fill="url(#night)"/>')
# Stars drift left.
slide([(0, 0, 0), (SAVER, 0, 0), (HANDOFF + 0.5, -40, 0), (T, -40, 0)], (-10, 0))
for _ in range(90):
    sx, sy, r = rng.uniform(0, W + 60), rng.uniform(12, 380), rng.uniform(0.6, 1.5)
    add(f'<circle class="tw{rng.randint(1, 3)}" cx="{sx:.1f}" cy="{sy:.1f}" r="{r:.2f}" fill="#c9d0dc"/>')
add("</g>")
# The moon climbs across the sky.
moon = [(0, 980, 230), (SAVER, 980, 230), (SAVER + 1.9, 930, 170), (SAVER + 3.8, 870, 128), (HANDOFF + 0.5, 800, 104), (T, 800, 104)]
slide(moon, (930, 170))
add('<circle r="150" fill="url(#moonglow)"/>')
add('<circle r="30" fill="#99a1ae" mask="url(#crescent)"/>')
add("</g>")


def hills(base, amp, k, width, phase):
    pts = []
    for i in range(0, int(width) + 1, 8):
        y = base + amp * (math.sin(i * 0.0042 * k + phase) * 0.5 + math.sin(i * 0.011 * k + 0.4 + phase) * 0.3 + math.sin(i * 0.026 * k) * 0.2)
        pts.append(f"{i},{y:.1f}")
    return f"M0,{H} L" + " L".join(pts) + f" L{width},{H} Z"


# Far hills, then near hills with signal posts, both scrolling.
slide([(0, 0, 0), (SAVER, 0, 0), (HANDOFF + 0.5, -160, 0), (T, -160, 0)], (-60, 0))
add(f'<path d="{hills(420, 34, 1.0, W + 400, 1.3)}" fill="#0b1019"/>')
add("</g>")
slide([(0, 0, 0), (SAVER, 0, 0), (HANDOFF + 0.5, -420, 0), (T, -420, 0)], (-150, 0))
add(f'<path d="{hills(470, 22, 1.7, W + 600, 4.0)}" fill="#080b12"/>')
for i, sx in enumerate(range(140, W + 600, 330)):
    add(f'<rect x="{sx}" y="482" width="2" height="46" fill="#151a24"/>')
    add(f'<circle cx="{sx + 1}" cy="482" r="18" fill="url(#sig{"r" if i % 3 == 1 else "g"})"/>')
add("</g>")
# The embankment and the rails.
add(f'<rect y="528" width="{W}" height="{H - 528}" fill="#05070b"/>')
add(f'<rect y="527" width="{W}" height="1.5" fill="#1d2230"/>')
# The mail train crosses once, left to right.
CAR_W, CAR_H, GAP, CARS = 118, 30, 6, 6
TRAIN = CARS * (CAR_W + GAP)
slide([(0, -TRAIN - 200, 0), (SAVER + 0.6, -TRAIN - 200, 0), (HANDOFF - 0.2, W + 60, 0), (T, W + 60, 0)], (180, 0))
for c in range(CARS):
    x0 = c * (CAR_W + GAP)
    add(f'<rect x="{x0}" y="{527 - CAR_H}" width="{CAR_W}" height="{CAR_H}" rx="3" fill="#0f131c"/>')
    if c == CARS - 1:
        continue
    for k in range(6):
        if rng.random() < 0.82:
            add(f'<rect x="{x0 + 10 + k * 18}" y="{527 - CAR_H + 9}" width="10" height="11" rx="1.5" fill="#d6b87e" fill-opacity=".78"/>')
add(f'<path d="M{TRAIN},{512} L{TRAIN + 220},{486} L{TRAIN + 220},{534} Z" fill="url(#beam)"/>')
add("</g>")
add("</g>")

# Signal Lamps: soft lamps drifting out of focus.
group(fade([(LAMPS_IN, WAKE)], 0.6, 0.04), False)
add(f'<rect width="{W}" height="{H}" fill="#020306"/>')
for i in range(24):
    x0, y0 = rng.uniform(-60, W + 60), rng.uniform(-40, H + 40)
    dx, dy = rng.choice([-1, 1]) * rng.uniform(25, 70), rng.choice([-1, 1]) * rng.uniform(12, 40)
    r = rng.uniform(26, 92)
    tint = rng.choice(list(LAMP_TINTS))
    slide([(0, x0, y0), (LAMPS_IN, x0, y0), (WAKE, x0 + dx, y0 + dy), (T, x0 + dx, y0 + dy)], (x0, y0))
    blink = ' class="blink"' if i % 7 == 3 else ""
    add(f'<circle{blink} r="{r:.1f}" fill="url(#lamp{tint})"/>')
    add("</g>")
add("</g>")

# ---------------------------------------------------------------- cursor
# Still while the desk is idle, hidden under the saver (it hides the
# cursor), then a nudge that ends the saver.

home = (430, 330)
nudged = (468, 352)


def tr(p):
    return f"translate({p[0] - 3:.1f}px, {p[1] - 4:.1f}px)"


k = anim("opacity", [(0, 0), (WAKE - 0.01, 0), (WAKE, 0.9), (WAKE + 0.45, 0), (T, 0)])
k2 = anim("transform", [(0, "scale(.3)"), (WAKE, "scale(.3)"), (WAKE + 0.45, "scale(1.6)"), (T, "scale(1.6)")])
add(f'<circle class="a ripple" style="animation-name:{k},{k2};transform-box:fill-box;transform-origin:center" cx="{nudged[0]}" cy="{nudged[1]}" r="18" fill="none" stroke="{FROST}" stroke-width="2.5" opacity="0"/>')
cur = anim("transform", [(0, tr(home)), (WAKE - 0.15, tr(home)), (WAKE + 0.1, tr(nudged)), (T - 0.4, tr(nudged)), (T, tr(home))])
seen = anim("opacity", [(0, 1), (SAVER + 0.3, 1), (SAVER + 0.5, 0), (WAKE - 0.15, 0), (WAKE - 0.1, 1), (T, 1)])
add(f'<g id="cursor" class="a" style="animation-name:{cur},{seen};animation-timing-function:cubic-bezier(.45,0,.25,1);transform:{tr(home)}">')
add('<path d="M0,0 L0,22 L6,17 L10,26 L14,24 L10,15 L18,15 Z" fill="#eceff4" stroke="#1d2024" stroke-width="1.4" stroke-linejoin="round"/>')
add("</g>")
add("</g></svg>")

out[STYLE_AT] = "<style>" + css + "\n".join(kfs) + "</style>"
Path(__file__).with_name("hero.svg").write_text("\n".join(out) + "\n")
print(f"wrote hero.svg ({sum(len(s) + 1 for s in out) // 1024} KB, {len(kfs)} keyframe sets)")
