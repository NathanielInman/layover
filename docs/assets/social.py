#!/usr/bin/env python3
"""Writes docs/assets/social.png: the 1280 × 640 preview GitHub shows when
the repo is linked. Night Mail from hero.svg's reduced-motion still, with the
name and the pitch over it. Needs google-chrome (or chromium) for the render.

Upload it under Settings → General → Social preview; GitHub has no API for it.

    python3 docs/assets/social.py
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
svg = (HERE / "hero.svg").read_text()

page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
html, body {{ margin: 0; width: 1280px; height: 640px; overflow: hidden; background: #05070c; }}
* {{ animation: none !important; }}
#cursor, .ripple {{ display: none; }}
.scene {{ position: absolute; left: -20px; top: -40px; width: 1320px; }}
.scene svg {{ width: 1320px; height: auto; display: block; }}
.band {{ position: absolute; inset: 0; background: linear-gradient(90deg, rgba(5,7,12,.92) 0%, rgba(5,7,12,.75) 42%, rgba(5,7,12,0) 70%); }}
.copy {{ position: absolute; left: 72px; top: 150px; width: 640px; font-family: "JetBrains Mono", "DejaVu Sans Mono", monospace; color: #d8dee9; }}
.mark {{ width: 64px; height: 64px; }}
h1 {{ font-size: 84px; margin: 18px 0 10px; letter-spacing: -1px; font-weight: 800; }}
p {{ font-size: 26px; line-height: 1.4; margin: 0; color: #c5c8c6; }}
.rule {{ margin-top: 26px; font-size: 19px; color: #88c0d0; }}
</style></head><body>
<div class="scene">{svg}</div>
<div class="band"></div>
<div class="copy">
  {(HERE / "mark.svg").read_text().replace('<svg ', '<svg class="mark" ', 1)}
  <h1>Layover</h1>
  <p>A screensaver for Wayland that looks after your monitor.</p>
  <p class="rule">GPU hacks · burn-in tested in CI · a lamp in waybar</p>
</div>
</body></html>"""

chrome = shutil.which("google-chrome-stable") or shutil.which("google-chrome") or shutil.which("chromium")
if not chrome:
    raise SystemExit("needs google-chrome or chromium")
with tempfile.TemporaryDirectory() as tmp:
    html = Path(tmp) / "social.html"
    html.write_text(page)
    out = HERE / "social.png"
    subprocess.run(
        [chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
         f"--user-data-dir={tmp}/profile", "--window-size=1280,640", f"--screenshot={out}", html.as_uri()],
        check=True, capture_output=True, timeout=120,
    )
print(f"wrote {out.relative_to(HERE.parent.parent)}")
