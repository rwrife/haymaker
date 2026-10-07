# Character model source assets

These five OBJ files were supplied by the user for future character integration. The initial four were supplied in T-pose; Atlas is a subsequent supplied export whose pose still needs verification during integration. They are stored here as art source assets, outside the app's synchronized resource directory.

| File | Character | Vertices | Faces |
| --- | --- | ---: | ---: |
| `mack.obj` | Mack, the player | 11,057 | 21,736 |
| `goldie.obj` | Goldie Voltage | 10,418 | 20,735 |
| `nico.obj` | Nico “Nightshift” Navarro | 10,864 | 21,095 |
| `bruiser.obj` | Bruiser Baxter, the final boss | 10,962 | 21,421 |
| `atlas.obj` | Atlas “Undertow” Reed | 21,000 | 22,375 |

The files are preserved byte-for-byte from the supplied exports. Their headers identify Blender 5.0.1. Vertex records include RGB colors; there are no external material-library references, UV coordinates, or exported normals. An importer needs to preserve vertex colors and generate normals as appropriate. OBJ does not carry a skeletal rig or animation, so T-pose alone does not make these assets animation-ready. Scale, orientation, rigging, and rendering still need verification during integration.

Atlas's export contains 3,379 triangle faces and 18,996 quad faces (22,375 faces total). Unlike the initial four triangulated models, Atlas needs triangulation if the destination renderer requires triangles.

See [character backstories](../character-backstories.md) for roles and story direction. The currently bundled meshes in `Haymaker/Models` remain the runtime assets.
