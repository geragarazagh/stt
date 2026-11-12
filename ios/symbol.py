# symbol.py writes Symbols.xcassets/stt.wave.symbolset: STT's own record sign, the 11 bars of the app icon (mac/icon.swift: three
# lobes 1 : 0.81 : 0.73, each 0.65 / 1 / 0.57, a small bar of silence between them), as an SF Symbols custom template
# (one weight, Regular-M; the system scales it with the text). Run by `make`.
import json, os
lobe, beats, quiet = [0.65, 1, 0.57], [1, 0.81, 0.73], 96 / 576
heights = []
for i, b in enumerate(beats):
    heights += [round(l * b * 576 / 32) * 32 / 576 for l in lobe]
    if i < 2: heights.append(quiet)
H = 82.0
W = H * 21 / 18                                # the icon's 21 : 18 box: 11 bars, 10 gaps
mid = -70.459 / 2                              # the middle of the cap height, as SF Symbols centre a glyph
def rrect(x, y, w, h):
    r = w / 2
    return (f"M{x+r:.3f} {y:.3f}H{x+w-r:.3f}A{r:.3f} {r:.3f} 0 0 1 {x+w:.3f} {y+r:.3f}V{y+h-r:.3f}"
            f"A{r:.3f} {r:.3f} 0 0 1 {x+w-r:.3f} {y+h:.3f}H{x+r:.3f}A{r:.3f} {r:.3f} 0 0 1 {x:.3f} {y+h-r:.3f}"
            f"V{y+r:.3f}A{r:.3f} {r:.3f} 0 0 1 {x+r:.3f} {y:.3f}Z")
def glyph(scale):
    # bar = gap at Regular; thinner bars for Ultralight, thicker for Black, the same pitch and heights
    pitch = W / 21 * 2; bar = W / 21 * scale
    return "".join(rrect(i * pitch + (pitch / 2 - bar) / 2 + (W / 21 - pitch / 2) / 2, mid - max(bar, h * H) / 2, bar, max(bar, h * H))
                   for i, h in enumerate(heights))
# Three designs, as Apple's template asks (Ultralight-S, Regular-S, Black-S); Xcode interpolates the other weights and
# makes the M and L sizes, so the symbol draws in any weight a place asks for. With Regular-M alone the Control
# gallery and Control Centre drew an empty circle (2026-11-11, his IMG_0251).
designs = [("Ultralight-S", 0.55, 559.0), ("Regular-S", 1.0, 1391.0), ("Black-S", 1.45, 2223.0)]
guides = "".join(
    f'  <line id="left-margin-{n}" x1="{x:.3f}" y1="600" x2="{x:.3f}" y2="720" stroke="#00ac8c" stroke-width="0.5"/>\n'
    f'  <line id="right-margin-{n}" x1="{x + W:.3f}" y1="600" x2="{x + W:.3f}" y2="720" stroke="#00ac8c" stroke-width="0.5"/>\n'
    for n, _, x in designs)
symbols = "".join(f'  <g id="{n}" transform="matrix(1 0 0 1 {x:.3f} 696)">\n   <path d="{glyph(k)}"/>\n  </g>\n'
                  for n, k, x in designs)
svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
 <g id="Notes">
  <text id="template-version" x="3036" y="292" text-anchor="end">Template v.3.0</text>
  <text id="descriptive-name" x="263" y="292">stt.wave</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" x1="263" y1="696" x2="3036" y2="696" stroke="#27aae1" stroke-width="0.5"/>
  <line id="Capline-S" x1="263" y1="625.541" x2="3036" y2="625.541" stroke="#27aae1" stroke-width="0.5"/>
  <line id="Baseline-M" x1="263" y1="1126" x2="3036" y2="1126" stroke="#27aae1" stroke-width="0.5"/>
  <line id="Capline-M" x1="263" y1="1055.54" x2="3036" y2="1055.54" stroke="#27aae1" stroke-width="0.5"/>
  <line id="Baseline-L" x1="263" y1="1556" x2="3036" y2="1556" stroke="#27aae1" stroke-width="0.5"/>
  <line id="Capline-L" x1="263" y1="1485.54" x2="3036" y2="1485.54" stroke="#27aae1" stroke-width="0.5"/>
{guides} </g>
 <g id="Symbols">
{symbols} </g>
</svg>
'''
out = "Symbols.xcassets/stt.wave.symbolset"
os.makedirs(out, exist_ok=True)
open(f"{out}/stt.wave.svg", "w").write(svg)
json.dump({"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": "stt.wave.svg", "idiom": "universal"}]},
          open(f"{out}/Contents.json", "w"), indent=2)
json.dump({"info": {"author": "xcode", "version": 1}}, open("Symbols.xcassets/Contents.json", "w"), indent=2)
