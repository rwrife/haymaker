# Fighter animation clips

`Haymaker/Models/fighter.clips` is the single animation library that every fighter plays.

- **Format:** compact binary HMC1, about 330 KB, 15 clips (the 14 contract clips plus an extra `cross`).
- **Built by:** `scripts/blender/extract_clips.py`, which bakes Mixamo motion-capture animations.
- **Checked by:** `scripts/test_fighter_clips.py` in CI.

## Sources

All clips come from [Mixamo](https://www.mixamo.com).

- **Character:** `ArtDirection/Models/mack.obj` was uploaded to Mixamo's auto-rigger with Skeleton LOD **No Fingers**,
  and every animation was downloaded on Mack.
- **Shared skeleton:** every FBX therefore uses the same 25-bone `mixamorig:` rest skeleton, which is
  `ArtDirection/Rigs/mixamo-reference-skeleton.json`. The extractor refuses an FBX with a different rest skeleton.
- **Download settings:**
  - format **FBX Binary**, **Without Skin**
  - keyframe reduction **none**
  - frame rate as offered (24 or 30 fps); the fps is read from each FBX and stored per clip, and frames are sampled
    1:1 with no resampling
- **File names:** keep Mixamo's names. The extractor looks for `<name>.fbx` in `--fbx-dir`, which defaults to
  `~/Downloads`.

> **Licence:** Mixamo content may be used in games, but the raw animation files may not be redistributed. Never commit
> an `.fbx`; only the derived `fighter.clips` bake belongs in the repo.

| FBX | Source frames @ fps | Clip | Stored frames | Loops | Processing |
|---|---|---|---|---|---|
| `Idle.fbx` | 54 @ 24 | `idle` | 53 | yes | duplicate end frame dropped; frame 0 is the shared **guard pose** |
| `LeftPunch.fbx` | 43 @ 24 | `jab` | 43 | | ends steered onto the guard; feet pinned |
| `Hook Punch.fbx` | 66 @ 30 | `hook` | 66 | | rear (right) hook; stance aligned to the guard's feet; lead glove held at the cheek through the wind-up; ends steered onto the guard; feet pinned |
| `UpperCut.fbx` | 54 @ 24 | `uppercut` | 54 | | lead (left) hand uppercut; rear glove held at the chin; ends steered onto the guard; feet pinned |
| `Center Block.fbx` | 49 @ 30 | `block` | 49 | | as authored (already starts and ends on the guard) |
| `Body Block.fbx` | 84 @ 24 | `bodyBlock` | 33 | | trimmed to source frames 20–52; ends steered onto the guard |
| `Left Block.fbx` | 47 @ 30 | `slip` | 47 | | as authored |
| `Head Hit.fbx` | 38 @ 30 | `hitHead` | 38 | | as authored |
| `Kidney Hit.fbx` | 35 @ 30 | `hitBody` | 31 | | lead-in trimmed (source frames 5–35); start steered onto the guard |
| `Side Hit.fbx` | 30 @ 30 | `hitSide` | 30 | | as authored |
| `Falling Down.fbx` | 69 @ 30 | `knockdown` | 69 | | re-rooted to fall backward; glove clamp (see Processing) |
| `Getting Up.fbx` | 82 @ 30 | `getUp` | 68 | | trimmed to source frames 1–68; aligned to the knockdown and walked home |
| `Victory.fbx` | 136 @ 30 | `victory` | 136 | | ends steered onto the guard |
| `WarmingUp.fbx` | 152 @ 24 | `warmup` | 151 | yes | duplicate end frame dropped (title-screen shadowboxing) |
| `RightPunch.fbx` | 52 @ 24 | `cross` (extra) | 52 | | lead jab of the source 1-2 replaced by a guard hold (frames 3–19); ends steered onto the guard; feet pinned |

Source frame ranges are 1-based, matching Blender and the `--report` notes. Marker frames are 0-based.

Two downloads are deliberately unused:

- `Boxing.fbx` is the UpperCut motion re-exported at 30 fps.
- `Climbing Ladder.fbx` is unrelated to boxing.

"Left" and "right" are anatomical. `jab` is thrown with the lead left hand. `hook` is Mixamo's "Hook Punch", thrown with
the rear right hand. `cross` is an extra clip outside the runtime contract, stored after `warmup`: Mixamo's "RightPunch",
a straight right to the body. It was the `hook` source until the real hook was downloaded. The runtime may ignore it.

## Regenerate

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 \
    --python scripts/blender/extract_clips.py -- [--fbx-dir ~/Downloads] [--out Haymaker/Models/fighter.clips] \
    [--report clips-report.json]
python3 scripts/test_fighter_clips.py
```

- **Blender:** tested with 5.2.1. The script uses Blender's bundled numpy.
- **Exit code:** `--python-exit-code 1` makes Blender exit non-zero on a Python error.
- **Determinism:** the same FBX files always produce the same bytes.
- **Report:** `--report` writes per-clip fps, frames and markers, plus a note for every edit made.

## Markers

Markers are 0-based frame indices into the stored clip, in ascending order. They are detected automatically from the
motion and were checked visually against rendered contact sheets.

**Punches** (`jab`, `hook`, `uppercut`, and the extra `cross`)

| Clip | Glove and drive axis | chamber | contact | recovered |
|---|---|---|---|---|
| `jab` | left glove, +Z | 4 | 12 | 39 |
| `hook` | right glove, +Z (arc) | 23 | 36 | 58 |
| `uppercut` | left glove, +Y (up) | 14 | 18 | 47 |
| `cross` | right glove, +Z | 10 | 16 | 40 |

- **chamber:** start of the glove's fast drive along its axis (velocity at least 25 % of its peak).
  - `hook` instead uses the **cocked** frame: it winds up (the glove drops low and back while the torso turns away), then
    sweeps. Its chamber is the frame where the glove's 3D speed bottoms out just before the sweep, so a held tell shows
    the loaded hook rather than a frame frozen mid-swing.
- **contact:** the glove's maximum reach along the axis, i.e. the first frame after the peak drive where it stops
  advancing. For `hook` that is the end of the horizontal arc: the glove has swept round in front of the face at head
  height, with an elbow angle of about 125° (180° is straight).
- **recovered:** the glove is back within 3 cm of its first-frame guard spot and the root is back home.

**Covers and dodges**

| Clip | Markers |
|---|---|
| `block` | guardUp 12, holdEnd 20 |
| `bodyBlock` | guardUp 10, holdEnd 14 |
| `slip` | slipped 15, holdEnd 19 |

- **guardUp / holdEnd:** the window where the upper body's excursion from frame 0 is at least 85 % of its peak (80 % for
  `bodyBlock`).
- **slipped:** the maximum lean. **holdEnd** (slip): the lean starts to come back.

**Hits** (`hitHead`, `hitBody`, `hitSide`)

| Clip | impact | recovered |
|---|---|---|
| `hitHead` | 2 | 29 |
| `hitBody` | 2 | 26 |
| `hitSide` | 2 | 26 |

- **impact:** head/torso speed first reaches 35 % of its peak.
- **recovered:** excursion drops back under 15 % of its peak.

**Knockdown and get-up**

| Clip | Markers |
|---|---|
| `knockdown` | react 3, ground 26, settled 40 |
| `getUp` | rise 2, standing 49 |

- **react:** first motion; the frames before it are the guard.
- **ground:** the hips land on the mat (within 1 cm of their lowest point).
- **settled:** torso speed stays under 25 % of its peak from here on.
- **rise:** first motion of the get-up.
- **standing:** the hips are back to 97 % of the final standing height.

**Victory**

| Clip | Markers |
|---|---|
| `victory` | armsUp 18, armsDown 99 |

- **armsUp / armsDown:** both gloves are above the head (also used as the taunt window).

## Format (HMC1, little endian)

```
header : char[4] "HMC1", u32 boneCount (=22), u32 clipCount, u32 reserved (0)
source : boneCount × { f32 head[3], f32 aim[3] }      Mixamo rest skeleton, armature space, OBJ units
clip × clipCount:
  char[24] name (ASCII, NUL padded), f32 fps, u32 frameCount, u32 flags (bit0 = loops), u32 markerCount
  markerCount × { char[16] name (NUL padded), f32 frame }
  frameCount  × { f32 hips[3]; boneCount × f32 quat[4] (x, y, z, w) }
```

Bones (index, name, parent):

```
 0 Hips -1          8 LeftForeArm 7     16 LeftFoot 15
 1 Spine 0          9 LeftHand 8        17 LeftToeBase 16
 2 Spine1 1        10 RightShoulder 3   18 RightUpLeg 0
 3 Spine2 2        11 RightArm 10       19 RightLeg 18
 4 Neck 3          12 RightForeArm 11   20 RightFoot 19
 5 Head 4          13 RightHand 12      21 RightToeBase 20
 6 LeftShoulder 3  14 LeftUpLeg 0
 7 LeftArm 6       15 LeftLeg 14
```

**Aim points.** Each bone's aim is the head of its child, except at the leaves:

- **Hand:** Mixamo's synthetic tail (the glove tip along the forearm).
- **Head:** the `HeadTop_End` head.
- **ToeBase:** the `Toe_End` head.

The Mixamo `*_End` bones themselves are dropped.

**Coordinates.**

- Armature space: Y up, +Z towards the opponent, +X the fighter's left.
- Units: Mack's OBJ units (about 1.0 tall).

**Per-frame data.**

- `hips`: the posed Hips head position.
- `quat`: the **global rest-relative delta** Δ(b,t) = G_anim(b,t)·G_rest(b)⁻¹. In Blender that is
  `pose_bone.matrix` × `bone.matrix_local`⁻¹.
- Every quaternion is unit length and hemisphere-continuous (q·q_prev ≥ 0).

**Retargeting.** The runtime maps the source skeleton onto each fighter's bind skeleton with a correction per bone:

- **Limbs:** shortest arc between the source and target aim directions.
- **Hands:** the forearm's correction.
- **Axial chain:** identity.
- **Hips translation:** scaled by the ratio of hip heights.

## Processing (what `extract_clips.py` does)

### 1. Sampling

Every source frame is sampled at native fps. For each frame the extractor stores Δ per bone (normalised and
sign-continuous) plus the hips position.

### 2. Guard pose

`idle` frame 0 is the shared guard pose.

- The idle hips are yawed −46°: a bladed orthodox stance.
- The idle hips sit at XZ ≈ (−0.005, 0.004), which is effectively the rest XZ.

### 3. Loops (`idle`, `warmup`)

- Mixamo repeats frame 0 as the last frame; that duplicate is dropped.
- Any residual between the last frame and the first is spread linearly over the clip as a local-rotation and hips
  offset. The residual was at most 0.01°.
- `idle` then gets the boot-sole floor fix (step 14) before its frame 0 becomes the guard, so every clip that starts or
  ends on the guard has its feet on the mat.

The wrap step (last frame → first) matches a normal frame step, so neither loop pops:

| Clip | Wrap step | Median frame step |
|---|---|---|
| `idle` | 3.8° | 4.8° |
| `warmup` | 5.1° | 15.7° |

### 4. Guard matching

Clips the runtime crossfades from and to idle must start and end on the guard. Each end is steered there with an
additive offset: the local-rotation difference to the guard plus the hips difference.

- The offset is applied in full on the end frame and fades out (smootherstep) over the clip's own wind-up or
  wind-down. The action itself (contact, cover, impact) is untouched.
- `block`, `slip`, `hitHead` and `hitSide` already start and end on the guard, because Mixamo's boxing pack shares the
  pose. They are left as authored. `hitBody` only needs its start re-matched after its lead-in is trimmed.
- **Result:** after matching, every clip that blends with idle has first and last frames within 0.0° / 0.000 of the
  guard.

### 5. De-drift

- Raw hips already return to their start XZ.
- In-place clips (shuffles and sways) wander at most 0.16 units.
- Punches keep their lunge (up to 0.36 units) and return exactly to their start.

### 6. `hook` and `cross`

- **`hook` stance:** `Hook Punch.fbx` was captured in a slightly different stance from the idle guard: its feet
  are about 8° rotated and up to 0.07 off. Before guard matching, the whole clip is rigidly re-rooted (yaw 8.3°, XZ shift
  (0.013, −0.045)) by a Procrustes fit of its frame-0 feet onto the guard's. Planted feet then stay put, and the hook
  lands on the same target line as the other punches: contact glove at x = −0.11 instead of −0.20.
- **`cross`:** the source is a 1-2 combination. The lead arm's jab (source frames 3–19) is replaced by a slerped hold of
  the guard arm, so the clip reads as a single straight right. (The `--report` note gives the same span as 0-based clip
  frames 2–18; the clip is untrimmed.)

### 7. Off-hand guard (`jab`, `hook`, `uppercut`, `cross`)

While one hand punches, the other glove must stay at the chin. For each punch the extractor measures how far the
non-punching glove leaves its idle-guard spot, in the chest (Spine2) frame so that torso turn and lean don't count.
Frames where the glove is no farther from the head than at guard count as zero: a lead glove tucked in to the cheek
while the torso turns into a cross is still a tight guard.

The off-hand arm (Shoulder, Arm, ForeArm, Hand) is held on its guard pose if that drift exceeds 0.12 units, or if the
glove centre comes within 0.03 of the top of the head:

- **Hold:** the chain's chest-relative local rotations are slerped onto the guard's with weight 0.88 up to `contact`.
- **Release:** the weight eases to 0 by `recovered`, handing back to the clip's own pose.
- **`hook` window:** the hold covers the wind-up only. It is full up to `chamber` and released by `contact`, so the lead
  glove keeps the source's natural tuck to the cheek as the torso turns into the punch.
- **Continuity:** globals are rebuilt from the edited locals, so the arm stays attached and continuous, and the clip
  still starts and ends exactly on the guard.

| Clip | Off-hand | Max drift (as authored → stored) | Highest point vs head top (as authored → stored) |
|---|---|---|---|
| `jab` | right | 0.070, kept as authored | 0.052 below |
| `hook` | left | 0.005 (the glove stays closer to the head than at guard) | 0.028 above → 0.043 below (held) |
| `uppercut` | right | 0.167 → 0.056 (held) | 0.066 above → 0.045 below |
| `cross` | left | 0.013, kept as authored (the glove tucks up to 0.10 closer to the head as the torso turns) | 0.047 below |

- **`hook`:** in the source, the lead glove stays high while the head dips into the wind-up. Together with the guard
  offset, that lifted it level with the crown.
- **`uppercut`:** the source swings the rear glove up beside and above the head during the wind-up.
- **Rejected:** holding `cross`'s lead arm in the chest frame flared the glove out beside the head.

### 8. Planted feet (punches)

Guard matching blends local-rotation offsets, which drags planted feet around: by up to about 0.1 units, worst in `hook`.
For each punch, the extractor detects plant runs on the source, where the ankle is low and nearly still.

- **Pin:** during each run the foot is pinned to its position and orientation at an anchor frame: the clip's first or
  last frame when the run touches a clip end, otherwise the run's middle.
- **Swings:** the corrections are eased across the swings between runs, and the legs are re-solved with two-bone IK.
- **Result:** foot slide during plants is now 0.000 in all four punches, and toes stay on the mat (lowest toe tip
  −0.005). Arms, hips and markers are unchanged, and the first and last frames stay exactly on the guard.
- **`victory`:** its feet are planted for the whole source, but guard matching tilted them into the mat (about 0.03 in
  the skinned rigs at frames 116–117). Its plant runs are pinned the same way, keeping each foot's authored
  orientation.

### 9. `bodyBlock`

The source covers only briefly mid-clip, then dips the gloves low. Source frames 20–52 are kept and both ends are
steered onto the guard.

### 10. `knockdown`

- **Start:** it starts on the guard. The guard offset is held until `react`, then fades out over 12 frames.
- **Fall direction:** Mixamo's fall twists about 55° sideways. A −40° yaw correction ramps in from `react` to just after
  `ground`, so the sprawl ends facing the way `getUp` starts.
  - The boxer now falls **backwards, away from the opponent**: the hips travel toward −Z and land about 20° off
    straight back.
- **Travel:** hips travel is scaled ×0.6 while falling and ×0.25 while sliding on the mat.
- **Feet:** planted feet stay pinned during this re-rooting (two-bone leg IK).

### 11. `getUp`: alignment and walk home

1. **Align:** a yaw-only Procrustes fit maps getUp's first pose onto the knockdown's last pose, setting getUp's
   starting facing and position.
2. **Walk home:** while the body is off the mat and moving, the root yaw and XZ are walked back, weighted by how much it
   is moving. The total walk is about 0.28 units, with planted feet pinned. The clip finishes standing exactly over
   idle's hips XZ, facing the same way as idle.
3. **Trim and settle:** the clip ends 18 frames after `standing`, and its end is steered onto the guard from `standing`.
4. **Seam:** the remaining pose difference to the knockdown's last frame (local rotations and hips) is offset in at
   frame 0 and faded out over 16 frames.

**Result:** knockdown's last frame and getUp's first frame are identical (0.04° / 0.00000; steps 14–15 work per
frame and keep it).

### 12. Glove and elbow clamp (`knockdown`, `getUp`)

Mixamo's lying and propping poses push the wrists under the mat once Mack's big gloves are on. Each arm is corrected
anatomically, so no bone twists about its own axis:

1. The whole arm swings about the shoulder (a ball joint) until the elbow is at least 0.035 above the mat.
2. The elbow bends or unbends about its own hinge until the glove centre is at least 0.07 above the mat. The hinge axis
   is measured from the clip in the upper arm's frame, and the flex stays within 3°–155°.
3. If the hinge alone can't get the glove there, the whole arm swings about the shoulder for the rest.

The three steps repeat (at most 4 passes) until nothing needs lifting, so a later step can't undo an earlier one.

- **Why a hinge:** an earlier version swung the forearm about an arbitrary axis. That twisted `knockdown`'s
  LeftForeArm up to 174° about its own axis, which candy-wrapped the forearm on the skinned fighters (frames 40–57).
  The hinge version twists it at most 5°.
- **No pops:** the lift eases in and out over a few frames.
- **Exact seam:** getUp's final pass is a hard clamp that leaves valid frames bit-identical, so the knockdown → getUp
  seam stays exact.

### 13. Punch follow-through (`jab`, `hook`, `uppercut`, `cross`)

Mixamo's lunges keep carrying the hips forward after the glove lands, which drives the attacker into the defender
(`uppercut`: 0.035 more after `contact`). After `contact` the forward (+Z) hips offset from the contact position, x, is
soft-capped at 0.012 (x → 0.012·tanh(x / 0.012) when positive). Velocity stays continuous at contact, the backward
settle is untouched, and planted feet are re-pinned afterwards (slide 0.000).

| Clip | Forward hips travel after `contact` (authored → stored) |
|---|---|
| `jab` | 0.016 → 0.010 |
| `hook` | 0.003 → 0.003 |
| `uppercut` | 0.035 → 0.012 |
| `cross` | 0.009 → 0.008 |

### 14. Boot soles on the mat (every clip)

Each boot is modelled by six sole points: two heel corners, two at the ball of the foot and two at the toe tip. All six
are on the mat in the rest pose. Wherever any of them dips below the mat, the ankle is raised by that amount with
two-bone leg IK, keeping the foot's orientation.

- **Easing:** the lift eases in and out over a few frames (around the wrap for loops).
- **Guard ends:** the lift tapers to 0 at the first and last frame, unless that frame sinks itself, so the guard ends
  and the knockdown → getUp seam stay exact.
- **Result:** no sole point is below the mat in any clip, `knockdown` and `getUp` included (lowest −0.000001). Before,
  the lowest sole point was:

  | Clip | Lowest sole point before |
  |---|---|
  | `getUp`, `cross` | −0.012 |
  | `knockdown` | −0.009 |
  | `jab` | −0.008 |
  | `warmup` | −0.007 |
  | `victory`, `uppercut` | −0.006 |
  | all other clips | ≥ −0.003 |

### 15. Limb twist limit (every clip)

Linear-blend skins candy-wrap when a limb bone twists far about its own axis. For UpperArm, ForeArm, UpLeg and Leg, the
twist of the bone's local rotation about its rest axis (swing-twist decomposition) is soft-limited:

| Bones | Limit | Kept as authored up to |
|---|---|---|
| Arm, ForeArm | 85°, 80° | 75°, 70° |
| UpLeg, Leg | 27° | 19° |

- **Saturation:** beyond the "kept as authored" value the twist saturates smoothly (tanh) at the limit.
- **Excess goes to the child:** the removed twist is handed to the child bone, by pre-multiplying the child's local
  rotation with the same rotation about the parent's axis. So the child's global rotation and every joint position are
  unchanged: nothing moves, feet stay planted, and loops, guard ends and the seam are preserved.
  - Arm and forearm hand their excess down to the rigid glove.
  - Thigh and shin hand theirs down to the boot.
- **Idle guard untouched:** the guard's own twists (LeftArm 69°, thighs ≤ 18°) stay as authored.

Max |twist| about the bone's own axis, before → after:

| Clip | Arms | Legs |
|---|---|---|
| `knockdown` | 174° (LeftForeArm, frame 41) → 84° | 28° → 26° |
| `getUp` | 88° → 82° | 59° (LeftUpLeg) → 27° |
| `hitHead` | 74° | 57° (RightUpLeg, frame 13) → 27° |
| `slip` | 72° | 37° → 27° |
| `hook` | 58° | 35° → 27° |
| All other clips | ≤ 78°, unchanged | ≤ 27° |

## QA

### Automated checks

`scripts/test_fighter_clips.py` uses only the standard library. It checks:

- **Layout:** magic, bone count and exact byte layout.
- **Source table:** matches `mixamo-reference-skeleton.json` within ±1e-4 (head and aim points, using the aim rule
  above).
- **Contract:** all 14 contract clips (and the extra `cross`) are present, with the right loop flags and their required
  markers ascending and in range.
- **Sample health:** unit quaternions, no NaN, hemisphere continuity.
- **Pops:** no single-frame pop (a step over 25° and more than 3× both neighbours), and no bone faster than 1600°/s.
- **Loops:** the idle and warmup wrap deltas.
- **Guard ends:** clips that blend with idle start and end on the guard.
- **Root:** the root's wander and its return to the start.
- **Knockdown → getUp:**
  - the seam is exact
  - `ground` is on the mat
  - the fall goes backward
  - getUp ends over the rest hips, with idle's facing and pose
  - getUp reaches standing height
- **Floor:**
  - in every frame, glove centres are at least 0.065 above the mat and toes no lower than −0.02
  - in every clip, boot-sole points (step 14) are no lower than −0.002
- **Twist:** no bone's local rotation twists 90° or more about its own rest axis, and UpLeg/Leg stay under 30°.
- **Follow-through:** in every punch, the hips travel less than 0.08 further forward after `contact`.
- **Off-hand guard:** in `jab`, `hook`, `uppercut` and `cross` the non-punching glove stays within 0.125 of its guard
  spot (same rule as step 7) and never rises above the top of the head.

### Visual review

The bake was also reviewed visually. A scratch Blender script (not in the repo) played `fighter.clips` on Mack using the
retarget rules above. It rendered:

- front and side contact sheets for every clip, plus front / three-quarter / top sheets for the punches
- crossfade strips (0.15 s blends) for idle → jab / hook / uppercut / cross / block / hitHead → idle
- a knockdown → getUp → idle strip
- both loop wraps
- close-ups of both forearms through knockdown frames 39–57, before and after the twist fix, with straight stripes
  painted down each limb so any twist shows as a spiral

## Known limitations

- **getUp drift:** getUp walks the root about 0.28 units back to centre while rising. The feet are pinned, so they don't
  skate, but the body drifts slightly. In the last 18 frames the fighter shuffles from the source's square stance into
  the bladed guard.
- **Short holds:** the holds in `block` (8 frames) and `bodyBlock` (4 frames) are short. For longer blocks, the runtime
  should hold or slow the clip between `guardUp` and `holdEnd`.
- **Lying sink:** the hips are as authored in `knockdown` and `getUp`. On the skinned fighters the seat dips about
  0.03–0.04 units (0.09–0.13 rig units) into the mat while lying, more on heavier builds. The runtime's verifier logs
  this as "lying sink" but doesn't fail on it.
- **Geometric clamp:** the glove clamp is purely geometric. It keeps elbows and gloves on top of the mat but does not
  model contact, so a supporting arm can look like it hovers slightly.
- **Toe snaps:** Mixamo slaps the toes flat in one frame at foot plants. This is kept as authored.
- **Hook reach:** a hook is a short punch. At `contact` the hook's glove is about 0.47 in front of the guard's hips,
  against 0.77 for the jab, so a hook only connects at close range unless the runtime closes the distance.
- **Wide hook:** Mixamo's hook is a wide, looping one with a big wind-up: the rear glove drops low and back while the
  torso turns away before the sweep (frames 10–23).
