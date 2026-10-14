# Character model source assets

These eight OBJ files were supplied by the user for future character integration. The initial four were supplied in T-pose; Atlas, Duke, Sylvie, and Cassian are subsequent supplied exports whose poses still need verification during integration. They are stored here as art source assets, outside the app's synchronized resource directory.

| File | Character | Vertices | Faces |
| --- | --- | ---: | ---: |
| `mack.obj` | Mack, the player | 11,057 | 21,736 |
| `goldie.obj` | Goldie Voltage | 10,418 | 20,735 |
| `nico.obj` | Nico “Nightshift” Navarro | 10,864 | 21,095 |
| `bruiser.obj` | Bruiser Baxter, the final boss | 10,962 | 21,421 |
| `atlas.obj` | Atlas “Undertow” Reed | 21,000 | 22,375 |
| `duke.obj` | Duke Doubletake | 21,581 | 23,026 |
| `sylvie.obj` | Sylvie “Slipstream” Sloane | 21,038 | 22,438 |
| `cassian.obj` | Cassian “Saint” Sterling | 21,215 | 23,190 |

The files are preserved byte-for-byte from the supplied exports. Their headers identify Blender 5.0.1. Vertex records include RGB colors; there are no external material-library references, UV coordinates, or exported normals. An importer needs to preserve vertex colors and generate normals as appropriate. OBJ does not carry a skeletal rig or animation, so T-pose alone does not make these assets animation-ready. Scale, orientation, rigging, and rendering still need verification during integration.

The subsequent exports contain mixed triangle and quad faces. Unlike the initial four triangulated models, these need triangulation if the destination renderer requires triangles.

| Model | Triangles | Quads |
| --- | ---: | ---: |
| Atlas | 3,379 | 18,996 |
| Duke | 3,518 | 19,508 |
| Sylvie | 3,773 | 18,665 |
| Cassian | 4,734 | 18,456 |

See [character backstories](../character-backstories.md) for roles and story direction. The currently bundled meshes in `Haymaker/Models` remain the runtime assets.
