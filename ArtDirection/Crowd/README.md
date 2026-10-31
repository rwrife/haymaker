# Crowd (issue #42)

The arena stands are filled with rigged, animated spectators generated with the [Tripo3D API](https://developers.tripo3d.ai).
There are four bodies and ten looks. Each body is about 5,000 triangles and plays four looping clips.

| Body | Looks (`Haymaker/Models/crowd-<look>.jpg`) | Triangles |
|---|---|---|
| `casual-man` | `tee-gray`, `polo-red`, `tee-green` (older, gray hair) | 4,958 |
| `suit-man` | `suit-charcoal`, `suit-navy`, `suit-brown` (older, gray hair) | 4,783 |
| `casual-woman` | `tee-teal`, `tee-yellow` | 4,786 |
| `business-woman` | `blazer-navy`, `blazer-burgundy` | 4,871 |

## Clips

| Runtime clip | Built from (Tripo `preset:biped:*`) | Notes |
|---|---|---|
| `sit` | `sit` | Seated idle; the base for the two seated composites. |
| `sit_clap` | `sit` + `clap` | Seated legs and pelvis from `sit`; spine, arms and head from `clap`. |
| `sit_yell` | `sit` + `angry_01` | Same composite as above: shouting and arm waving from a seat. |
| `cheer` | `cheer` | Stands up and cheers, with both arms overhead. The stand-up and sit-down are 0.8 s crossfades, and the clip is moved forward so the feet land where the seated feet rest. |

Each spectator picks a clip, holds it for a random time and crossfades to the next. Everyone has their own seed, phase and speed, so the stands never move in unison. Heavy blows raise an excitement level that shifts picks toward clapping, yelling and standing. Knockdowns and the career win make most of the crowd jump up. Reduced Motion pauses the crowd. The randomness never touches the fight RNG.

## Pipeline

1. **Generate** (`/v3/generation/text-to-model`, model `v3.1-20260211`, `face_limit: 5000`): one A-pose body per prompt.
2. **Rig** (`/v3/animations/rig-check` then `/v3/animations/rig`, `v1.0-20240301`, `spec: mixamo`): the same 22 Mixamo bones as the fighters, plus a `Root`.
3. **Animate** (`/v3/animations/retarget`, `animate_in_place: true`): `sit`, `clap`, `cheer` and `angry_01` in one GLB per body. These are `source/<body>.glb`.
4. **Re-texture** (`/v3/models/texture` on the body's generation task): six extra looks, `source/<look>.jpg`. Tripo returns the same mesh and UVs, only in a different vertex order. The bake checks this, so the look textures map directly onto the rigged mesh. Each body's own look is the texture embedded in its GLB.
5. **Bake** (`python3 scripts/build_crowd.py`, needs Pillow): turns each rig to face +Z with Y up and feet on y = 0. It folds the animated `Root` into the hips, builds the seated composites, smooths the loop seams, measures the bench height under the seated pelvis and writes:
   - `Haymaker/Models/<body>.crowd` (CRW1, about 630 KB each)
   - `Haymaker/Models/crowd-<look>.jpg` (512 px, 30–46 KB each)

   The bake is byte-for-byte reproducible.
6. **Check** (`python3 scripts/test_crowd.py`, stdlib): verifies the format, triangle budget, weights, UVs and bind pose. It also CPU-skins every clip to confirm seated pelvis height, standing feet on the floor, facing direction, loop seams and quaternion continuity. The existing suite also contains a legacy roster comparison; it is not a requirement to maintain a second game.
7. **Stage for Godot:** copy the generated `.crowd` and `crowd-<look>.jpg` files from the tooling's `Haymaker/Models/` output into `godot/assets/models/`.

`crowd.json` records the prompts' outputs as Tripo task IDs (`tripo.bodies`, `tripo.textures`) for provenance.

Generation cost: 410 Tripo credits (US$4.10) across 22 tasks, including the probe tasks that became the `casual-man` body.

## CRW1 format (little-endian)

```
header   char[4] "CRW1", u32 vertexCount, u32 indexCount, u32 boneCount (23), u32 clipCount, f32 height, f32 seat
bones    boneCount × { i32 parent, f32[3] translation, f32[4] rotation (x, y, z, w), f32[16] inverseBind (column-major) }
vertices vertexCount × { f32[3] position, f32[3] normal, f32[2] uv, f32[4] weights, u16[4] bones }   (56 bytes)
indices  u16 × indexCount, zero-padded to 4 bytes
clips    clipCount × { char[16] name, f32 fps, u32 frames,
                       f32[4] × frames × boneCount rotations (local, frame-major),
                       f32[3] × frames hips translation }
```

Bone order: `Root, Hips, Spine, Spine1, Spine2, Neck, Head, LeftShoulder, LeftArm, LeftForeArm, LeftHand, RightShoulder, RightArm, RightForeArm, RightHand, LeftUpLeg, LeftLeg, LeftFoot, LeftToeBase, RightUpLeg, RightLeg, RightFoot, RightToeBase`. `Root` is static in every clip. Units are body heights (height ≈ 1). `seat` is the bench height under the seated pelvis, and the scene scales each body so that its seat lands on a 0.55 m bench.

## Runtime

`godot/scripts/arena/crowd.gd` parses the CRW1 assets, caches meshes per look and shares each body's AnimationLibrary across spectator skeletons. The Godot arena creates the stepped stands and 105 fans. Crowd assets and textures are loaded from `godot/assets/models/`; crowd randomness stays separate from the deterministic match engine.
