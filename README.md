# Escher Studio

<p align="center">
  <img src="docs/hero.jpg" alt="Koloman Moser's ravens, deformed in Escher Studio">
</p>

Escher Studio is a native macOS app for reshaping repeating patterns **without breaking their symmetry**. Place a handle, drag it, and every translated, rotated, mirrored, or glide-reflected copy moves with it. The pattern deforms smoothly while remaining a seamless tiling, with no gaps or overlaps.

It supports all **17 wallpaper groups**, runs edits in real time on the GPU, and exports seamless images. You can start from historical ornament or generate a tiling of your own.

## Editing in action

Koloman Moser's *Die tausend Raben* (1901) is built from a single interlocking raven. Moving one part reshapes all the ravens, while the light and dark birds continue to fit together.

<p align="center">
  <img src="docs/raven.png" width="720" alt="A raven tile before and after an edit">
</p>

Three more examples, shown **before** and **after** deformation:

<table>
  <tr>
    <th align="center">Moser · <i>Die reciproken Tänzerinnen</i></th>
    <th align="center">Jones · <i>The Grammar of Ornament</i></th>
    <th align="center">Moser · <i>Astarta</i></th>
  </tr>
  <tr><th colspan="3" align="center">Original</th></tr>
  <tr>
    <td width="33%"><img src="docs/gallery/dancers-original.jpg" alt="Dancers, original"></td>
    <td width="34%"><img src="docs/gallery/jones-cm-original.jpg" alt="Owen Jones ornament, original"></td>
    <td width="33%"><img src="docs/gallery/astarta-original.jpg" alt="Astarta, original"></td>
  </tr>
  <tr><th colspan="3" align="center">Edited</th></tr>
  <tr>
    <td><img src="docs/gallery/dancers.jpg" alt="Dancers, edited"></td>
    <td><img src="docs/gallery/jones-cm.jpg" alt="Owen Jones ornament, edited"></td>
    <td><img src="docs/gallery/astarta.jpg" alt="Astarta, edited"></td>
  </tr>
</table>

## The 17 wallpaper groups

Every wallpaper group, after a few edits. Most examples are based on Owen Jones's *The Grammar of Ornament*; `p3m1` is Moser's *Arachne*, while `pgg` and `p31m` are generated tilings.

<table>
  <tr>
    <td colspan="2" rowspan="2" width="50%" align="center">
      <img src="docs/gallery/jones-p4m.jpg" alt="p4m wallpaper pattern"><br>
      <code>p4m</code>
    </td>
    <td width="25%" align="center"><img src="docs/gallery/jones-p1.jpg" alt="p1 wallpaper pattern"><br><code>p1</code></td>
    <td width="25%" align="center"><img src="docs/gallery/jones-p2.jpg" alt="p2 wallpaper pattern"><br><code>p2</code></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/gallery/jones-pm.jpg" alt="pm wallpaper pattern"><br><code>pm</code></td>
    <td align="center"><img src="docs/gallery/jones-pg.jpg" alt="pg wallpaper pattern"><br><code>pg</code></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/gallery/jones-cm.jpg" alt="cm wallpaper pattern"><br><code>cm</code></td>
    <td align="center"><img src="docs/gallery/jones-pmm.jpg" alt="pmm wallpaper pattern"><br><code>pmm</code></td>
    <td align="center"><img src="docs/gallery/jones-pmg.jpg" alt="pmg wallpaper pattern"><br><code>pmg</code></td>
    <td align="center"><img src="docs/gallery/pgg.png" alt="pgg wallpaper pattern"><br><code>pgg</code></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/gallery/jones-cmm.jpg" alt="cmm wallpaper pattern"><br><code>cmm</code></td>
    <td align="center"><img src="docs/gallery/jones-p4.jpg" alt="p4 wallpaper pattern"><br><code>p4</code></td>
    <td align="center"><img src="docs/gallery/jones-p4g.jpg" alt="p4g wallpaper pattern"><br><code>p4g</code></td>
    <td align="center"><img src="docs/gallery/jones-p3.jpg" alt="p3 wallpaper pattern"><br><code>p3</code></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/gallery/arachne.jpg" alt="p3m1 wallpaper pattern"><br><code>p3m1</code></td>
    <td align="center"><img src="docs/gallery/p31m.png" alt="p31m wallpaper pattern"><br><code>p31m</code></td>
    <td align="center"><img src="docs/gallery/jones-p6.jpg" alt="p6 wallpaper pattern"><br><code>p6</code></td>
    <td align="center"><img src="docs/gallery/jones-p6m.jpg" alt="p6m wallpaper pattern"><br><code>p6m</code></td>
  </tr>
</table>

## Build and run

Requires **macOS 13+** on a Mac with Metal, the Xcode Command Line Tools (`xcode-select --install`), and **CMake 3.20+**.

Clone with the Metal-cpp submodule, then build:

```sh
git clone --recurse-submodules https://github.com/catenacciA/escher-studio.git
cd escher-studio
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
open build/EscherStudio.app
```

To run the tests:

```sh
ctest --test-dir build
```

For an end-to-end smoke test covering every group and example:

```sh
build/EscherStudio.app/Contents/MacOS/EscherStudio --smoke-test /tmp/escher
```

## Controls

Choose an example or wallpaper group from the toolbar menu. Click anywhere to add a handle, then drag it; you can drag any symmetric copy. The slider controls the reach of an edit: moving it right makes the deformation more local.

| Action | Control |
| --- | --- |
| Pan · zoom | Two-finger scroll · pinch or ⌘-scroll |
| Compare with the original | Hold Space |
| Delete the selected handle | ⌫ |
| Random edit | ⌘R |
| New tile shape · palette (generated tilings) | ⌘N · ⌘1–⌘3 |
| Undo · redo | ⌘Z · ⇧⌘Z |
| Open · save · export | ⌘O · ⌘S · ⌘E |

## How it works

Each handle defines a displacement field over the plane. Every symmetry of the selected wallpaper group contributes a transformed copy of that field. The infinite sum has a closed-form solution, so it is inexpensive to evaluate. A small linear solve places handles exactly where they are dropped. The resulting field deforms a GPU mesh, through which the pattern—stored as one periodic tile—is redrawn.

The implementation follows Crane He Chen and Vladimir G. Kim, [*Escher Tile Deformation via Closed-Form Solution*](https://doi.org/10.1145/3721238.3730681) (SIGGRAPH 2025).

## Credits and licenses

The historical examples are drawn from:

- **Koloman Moser**, *Die Quelle: Flächenschmuck* (1901). Public-domain scans from the Cooper Hewitt, Smithsonian Design Museum.
- **Owen Jones**, *The Grammar of Ornament* (1856). Pattern cells restored by Martin von Gagern under **CC BY-SA 3.0**, which applies to those images only.

See [resources/artwork](resources/artwork/README.md) for individual image sources. The application code is [MIT-licensed](LICENSE); the Metal-cpp dependency is licensed under Apache 2.0.
