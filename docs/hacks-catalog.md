# The xscreensaver catalog, and what Layover takes from it

xscreensaver ships about 250 hacks. This page sorts them by what Layover's
renderer would need to draw them, and by how well each fits rule one. It is
the source for the `layover` tasks in Waybill (`ref:hacks-catalog`).

Layover reimplements ideas, never code: each hack is written fresh in WGSL,
gets its own name, and credits the xscreensaver hack and author it follows in
its header comment and in `layover hacks`. Every one passes `layover wear`
before it joins the rotation.

## What the renderer can do today

Every Layover hack is one WGSL fragment shader (`crates/layover-hacks/src/hacks/`)
on top of `prelude.wgsl`. It gets time, canvas size and the board's storage
buffer, draws one pixel at a time, and keeps no memory between frames unless it
opts into Tier S (`feedback: Some(...)`), which steps ping-pong `Rgba16Float`
state textures with a per-hack fade before drawing. The care pass and the
limiter run after it. That covers anything a pixel can work out from time and
position alone (fields, waves, fractals, tunnels, raymarched 3D) plus
reaction-diffusion and other continuous state fields. The Departure Board shows
a glyph atlas works too.

Most of xscreensaver is not like that. Its hacks draw onto a canvas that
keeps what was drawn, move thousands of particles, or render meshes. Each tier
below names what the renderer would gain to cover it.

| tier | needs | status |
|------|-------|--------|
| F | a fragment shader | works today |
| R | raymarching helpers in the prelude (SDFs, normals, soft light) | works today |
| S | state: ping-pong feedback textures that persist between frames | works today |
| P | particles: storage buffers and a compute pass | engine task |
| L | lines and shapes: instanced quads with SDF edges | engine task |
| M | meshes: vertex buffers and a depth buffer | engine task |
| T | text: the glyph atlas the Departure Board already has | works today |
| I | an image source: a screen grab or a picture folder | needs a decision |
| X | not ported (reason given) | |

## Rule one, applied to the catalog

- **Accumulating hacks (S) are the risky ones.** A canvas that keeps its
  marks is a still image by another name. Each S hack fades its history on a
  clock shorter than `max_dwell`, and the wear test has to run its state, not
  just its shader.
- **Hacks that draw and hold** (Maze, Penrose tiling filling in, Polyominoes)
  need a fade and a reset, or they are skipped.
- **Text hacks** fall under `text_rotate` (3 minutes) and must move. Rain and
  crawls move; terminals and fake crash screens do not.
- **Flashing.** Lightning, Hypnowheel, Greynetic and Popsquares flash or
  strobe. That is a people problem as much as a panel one; it waits on a
  decision about a flash cap.

## The catalog

### Fields, waves and tunnels (F)

Quasicrystal, Interference, Moire, Moire2, CWaves, Gflux, Marbling, Swirl,
Imsmap, Rorschach, Kaleidescope, Starfish, Halftone, Wormhole, Timetunnel,
Atunnel, Deepstars (Starfield is close already), Unknown Pleasures.

The easiest wave: each is a few dozen lines on today's renderer.

### Fractals and tilings (F, some R)

Julia, XLyap, Apollonian, Sierpinski, Sierpinski3D (R), Menger (R), Penrose,
Truchet, Voronoi, Hilbert, Celtic, CCurve, Lavalite and Metaballs (R).

### Orbits and attractors (S)

Flame, IFS, Hopalong, Strange, Thornbird, Discrete, Fiberlamp, Crystal, Coral.
They plot millions of points into a canvas that keeps them. On the GPU that is
a compute pass splatting into a feedback texture, faded each frame.

### Growth and automata (S)

Substrate, Cloudlife, Petri, Demon, RD-Bomb, Interaggregate, Intermomentary,
Vermiculate, Wander, Ant, Loop, Maze (with a fade), XFlame, Eruption,
Fireworkx, Pyro.

### Particles and swarms (P)

Galaxy, Grav, Fluidballs, Attraction, XRaySwarm, Anemotaxis, Flurry, GLSchool,
Euler2D, Whirlwindwarp, Bubbles, FuzzyFlakes, Swarm, Worm, Blaster.

### Curves and line art (L)

Qix, Lissie, Lisa, Lmorph, XSpirograph, Epicycle, Helix, Laser, Hypercube,
Polytopes, Hyperball, Rotor, Braid, Kumppa, Nerverot, Triangle, Vines,
Mountain.

### 3D scenes (M, some R)

Raymarchable: Superquadrics, Klein, Hypertorus, Moebius, Spheremonics,
MirrorBlob, GLKnots, Splodesic, Sphereeversion.

Meshes: Pipes, Gears, Molecule, Polyhedra, Hextrail, Cubenetic, CubeStack,
Boxed, GLPlanet, Atlantis, Engine, Pinion, Rubik, GLSnake, CityFlow,
Blocktube, Energystream, Skytentacles, Tronbit, Discoball, Crumbler,
Hydrostat, Peepers, Raverhoop, Nakagin, Chompytower, Squirtorus, Covid19.

### Text (T)

GLMatrix and XMatrix (rain), Starwars (crawl), Fontglide, FlipText, GLText,
Gibson, Unicode, Noseguy, Barcode. Phosphor and Apple2 are terminals that sit
still; they need scrolling and a short clock or they are skipped.

### Image hacks (I)

Distort, Ripples, Decayscreen, Spotlight, Zoom, Twang, Slip, BlitSpin,
Rotzoomer, FlipScreen3D, Jigsaw, GLSlideshow, Photopile, Tessellimage,
Carousel, Esper, Bumps, AnalogTV.

xscreensaver feeds these a grab of the desktop. On Wayland that is
`ext-image-copy-capture` (or wlr-screencopy), and it puts whatever was open on
the screen in front of anyone who walks past. A picture folder avoids that.

### Not ported (X)

- **BSOD**: fake crash screens, still text by design.
- **LCDScrub**: drives full white to "exercise" panels, which is the opposite
  of `max_drive`.
- **Webcollage**: pulls random images off the web.
- **Sonar**: pings the local network.
- **Lament, Flying Toasters, Pacman**: built on someone else's film, product
  or game.
