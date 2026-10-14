# Bundled artwork

The example textures come from two collections. Neither is covered by Escher Studio's MIT
license.

## Koloman Moser, *Die Quelle: Flächenschmuck* (1901): public domain

| Texture | Work | Group | Source scan | Museum record |
| --- | --- | --- | --- | --- |
| `ravens.jpg` | *Die tausend Raben* (A Thousand Ravens), plate 11 | pg | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Print,_Die_Tausend_Raben_Vorsatz_Papier_(A_Thousand_Ravens_Book_End_Paper),_plate_11,_in_Die_Quelle-_Flächen_Schmuck_(The_Source-_Ornament_for_Flat_Surfaces),_1901_(CH_18670543).jpg) | [Cooper Hewitt 1999-41-1-12](https://collection.cooperhewitt.org/objects/18670543) |
| `dancers.jpg` | *Die reciproken Tänzerinnen* (The Reciprocal Dancers), plate 25 | cm | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Print,_Die_reciproken_Tänzerinnen_(Reciprocal_Dancers),_Plate_25,_in_Die_Quelle-_Flächen_Schmuck_(The_Source-_Ornament_for_Flat_Surfaces),_1901_(CH_18670531).jpg) | [Cooper Hewitt 1999-41-1-26](https://collection.cooperhewitt.org/objects/18670531) |
| `astarta.jpg` | *Astarta*, wallpaper, plate 30 | cm | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Print,_Tapete_Astarta_(Astarta_Wallpaper),_plate_30,_in_Die_Quelle-_Flächen_Schmuck_(The_Source-_Ornament_for_Flat_Surfaces),_1901_(CH_18670501).jpg) | [Cooper Hewitt 1999-41-1-31](https://collection.cooperhewitt.org/objects/18670501) |
| `arachne.jpg` | *Arachne*, upholstery fabric, plate 18 | p3m1 | [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Print,_Mobelbezug_Arachne_(Arachne_Upholstery_Fabric),_plate_18,_in_Die_Quelle-_Flächen_Schmuck_(The_Source-_Ornament_for_Flat_Surfaces),_1901_(CH_18670493).jpg) | [Cooper Hewitt 1999-41-1-19](https://collection.cooperhewitt.org/objects/18670493) |

- **Author:** Koloman Moser (Vienna, 1868–1918). These are color lithographs published by Martin
  Gerlach.
- **Scans:** Cooper Hewitt, Smithsonian Design Museum, gift of Jerrol E. Golden.
- **License:** public domain (`{{PD-Art|PD-old-70-1923}}` on Commons). Faithful scans of
  two-dimensional public-domain works carry no new copyright, and Escher Studio claims none in the
  textures. Attribution is given as a courtesy.

## Owen Jones, *The Grammar of Ornament* (1856): CC BY-SA 3.0

The textures `jones-<group>.jpg` (p1, p2, pm, pg, cm, pmm, pmg, cmm, p4, p4m, p4g, p3, p6, p6m)
are cells of Owen Jones's plates. Martin von Gagern restored them as exactly periodic tiles and
published them in his
[Symmetry Blendings](https://commons.wikimedia.org/wiki/Symmetry_Blendings#Wallpaper_groups),
one per wallpaper group. Each texture comes from the PNG cell embedded in the corresponding SVG,
`File:SymBlend <group>.svg` on Wikimedia Commons.

- **License:** [CC BY-SA 3.0 DE](https://creativecommons.org/licenses/by-sa/3.0/de/deed.en),
  © Martin von Gagern. The original plates (London, 1856) are in the public domain;
  [digital edition](http://digital.library.wisc.edu/1711.dl/DLDecArts.GramOrnJones).
- **Share-alike:** the `jones-*.jpg` textures, and any image rendered from them (including
  `docs/gallery/jones-*` and exports of these examples), are adaptations. They are distributed
  under the same CC BY-SA 3.0 license with this attribution. The license applies only to these
  images, not to Escher Studio's code.

## Preparation

Each texture is a seamless tile of its pattern, resampled from the source without redrawing
anything. Before an example was included, its wallpaper group was checked
against the source. `artworks.json` records the lattice the app uses for each example.
