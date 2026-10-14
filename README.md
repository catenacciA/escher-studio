# Escher Studio

<p align="center"><img src="docs/hero.jpg" alt="Koloman Moser's ravens after editing"></p>

Escher Studio is a macOS app for editing periodic patterns while keeping their symmetry. You place
handles on a pattern and drag them, and the pattern deforms smoothly. Every copy of a dragged
point moves with it, whether that copy is translated, rotated, mirrored or glide-reflected under
the pattern's wallpaper group. The result is still a seamless tiling: tiles stay interlocked,
with no gaps or overlaps.

All 17 wallpaper groups are supported. Historical patterns by Koloman Moser and Owen Jones are
included as examples, and the app can generate simple tilings for any group. Edits run in real
time on the GPU and can be exported as seamless images.

## Examples

Moser's *Die tausend Raben* (1901) is tiled by a single raven shape. Below is one raven before
and after the edit shown at the top of this page. Every raven is a copy of the same tile, so the
change applies to all of them, and the light and dark birds still fit together.

<p align="center"><img src="docs/raven.png" width="720" alt="One raven before and after the edit"></p>

The same kind of edit applies to other patterns. Originals are on the left, edited versions on
the right.

<table>
<tr><th>Original</th><th>Edited</th></tr>
<tr>
<td><img src="docs/gallery/dancers-original.jpg" alt="dancers, original"></td>
<td><img src="docs/gallery/dancers.jpg" alt="dancers, edited"></td>
</tr>
<tr><td colspan="2" align="center"><sub>Koloman Moser, <i>Die reciproken Tänzerinnen</i>, 1901 · <code>cm</code></sub></td></tr>
<tr>
<td><img src="docs/gallery/jones-cm-original.jpg" alt="jones-cm, original"></td>
<td><img src="docs/gallery/jones-cm.jpg" alt="jones-cm, edited"></td>
</tr>
<tr><td colspan="2" align="center"><sub>Owen Jones, <i>The Grammar of Ornament</i>, 1856 · <code>cm</code></sub></td></tr>
<tr>
<td><img src="docs/gallery/astarta-original.jpg" alt="astarta, original"></td>
<td><img src="docs/gallery/astarta.jpg" alt="astarta, edited"></td>
</tr>
<tr><td colspan="2" align="center"><sub>Koloman Moser, <i>Astarta</i>, 1901 · <code>cm</code></sub></td></tr>
</table>

## Wallpaper groups

Each group, after a few edits. The patterns come from Owen Jones's *The Grammar of Ornament*,
except p3m1 (Moser's *Arachne*) and pgg and p31m (generated tilings).

<table>
<tr><td align="center" width="25%"><img src="docs/gallery/jones-p1.jpg" alt="p1"><br><code>p1</code></td><td align="center" width="25%"><img src="docs/gallery/jones-p2.jpg" alt="p2"><br><code>p2</code></td><td align="center" width="25%"><img src="docs/gallery/jones-pm.jpg" alt="pm"><br><code>pm</code></td><td align="center" width="25%"><img src="docs/gallery/jones-pg.jpg" alt="pg"><br><code>pg</code></td></tr>
<tr><td align="center" width="25%"><img src="docs/gallery/jones-cm.jpg" alt="cm"><br><code>cm</code></td><td align="center" width="25%"><img src="docs/gallery/jones-pmm.jpg" alt="pmm"><br><code>pmm</code></td><td align="center" width="25%"><img src="docs/gallery/jones-pmg.jpg" alt="pmg"><br><code>pmg</code></td><td align="center" width="25%"><img src="docs/gallery/pgg.png" alt="pgg"><br><code>pgg</code></td></tr>
<tr><td align="center" width="25%"><img src="docs/gallery/jones-cmm.jpg" alt="cmm"><br><code>cmm</code></td><td align="center" width="25%"><img src="docs/gallery/jones-p4.jpg" alt="p4"><br><code>p4</code></td><td align="center" width="25%"><img src="docs/gallery/jones-p4m.jpg" alt="p4m"><br><code>p4m</code></td><td align="center" width="25%"><img src="docs/gallery/jones-p4g.jpg" alt="p4g"><br><code>p4g</code></td></tr>
<tr><td align="center" width="25%"><img src="docs/gallery/jones-p3.jpg" alt="p3"><br><code>p3</code></td><td align="center" width="25%"><img src="docs/gallery/arachne.jpg" alt="p3m1"><br><code>p3m1</code></td><td align="center" width="25%"><img src="docs/gallery/p31m.png" alt="p31m"><br><code>p31m</code></td><td align="center" width="25%"><img src="docs/gallery/jones-p6.jpg" alt="p6"><br><code>p6</code></td></tr>
<tr><td align="center" width="25%"><img src="docs/gallery/jones-p6m.jpg" alt="p6m"><br><code>p6m</code></td><td></td><td></td><td></td></tr>
</table>

## Building

Escher Studio needs macOS 13 or later on a Mac with Metal, the Command Line Tools
(`xcode-select --install`) and CMake 3.20 or later.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
open build/EscherStudio.app
```

Run the tests with `ctest --test-dir build`. For an end-to-end check of every group and example,
run:

```sh
build/EscherStudio.app/Contents/MacOS/EscherStudio --smoke-test /tmp/escher
```

## Usage

Choose an example or a wallpaper group from the menu at the left of the toolbar. Click the
pattern to add a handle, then drag it; any copy of a handle can be dragged. The slider sets how
far an edit reaches: further right is more local.

| Action | Control |
| --- | --- |
| Pan · zoom | Two-finger scroll · pinch or ⌘-scroll |
| Compare with the original | Hold Space |
| Delete the selected handle | ⌫ |
| Random edit | ⌘R |
| New tile shape · palette (generated tilings) | ⌘N · ⌘1 – ⌘3 |
| Undo · redo | ⌘Z · ⇧⌘Z |
| Open · save · export | ⌘O · ⌘S · ⌘E |

## How it works

Each handle defines a displacement field over the plane. For each symmetry of the wallpaper
group, the field includes a transformed copy of the handle. Summing infinitely many copies has a
closed form, so the field is exact and cheap to evaluate. A small linear solve places every
handle exactly where it is dropped. The field is evaluated on a mesh on the GPU, and the pattern,
stored as one periodic tile, is redrawn through it.

## Credits

The deformation follows Crane He Chen and Vladimir G. Kim,
[*Escher Tile Deformation via Closed-Form Solution*](https://doi.org/10.1145/3721238.3730681),
SIGGRAPH 2025.

The examples come from two sources:

- Koloman Moser's *Die Quelle: Flächenschmuck* (1901), public domain, from scans by the Cooper
  Hewitt, Smithsonian Design Museum.
- Owen Jones's *The Grammar of Ornament* (1856), from cells restored by Martin von Gagern under
  CC BY-SA 3.0. That license applies to those images only.

[resources/artwork](resources/artwork/README.md) lists every source. The code is under the
[MIT license](LICENSE), and the bundled Metal-cpp under Apache 2.0.
