# Visual references and asset provenance

The user's supplied boxing screenshot is the composition and mood reference. The arena and characters are 3D meshes rendered in Godot. These PNGs are concept references only, not runtime backgrounds, sprite sheets, or screenshot substitutes.

Created with the built-in imagegen tool. The three final images were copied into this directory from the tool's generated-images output. No external stock assets or runtime image services are used.

## arena-reference.png

Prompt:

> Use case: stylized-concept. Asset type: background for a native arcade boxing game, landscape 16:9. Create ONLY an empty boxing arena seen from inside the ring at waist height, in polished hand-painted 3D comic arcade video game style matching the attached user's boxing screenshot: dark enormous packed crowd grandstands, bright cold blue-white overhead spotlights with volumetric shafts and camera flashes, red white blue ropes receding to corner posts across the middle distance, pale ivory canvas mat taking the lower 35 percent with an original subtle gold/navy geometric boxing crest at center. Cinematic navy shadows, dramatic lighting, crisp painterly texture and ink outlines. Camera aimed straight toward far end of ring. Center open for compositing large fighters. NO people in the ring, NO fighters, NO gloves, NO HUD, NO UI, NO lettering, NO watermark. It is the environment layer of a playable game, not a screenshot.

## baxter-reference.png

Prompt:

> Use case: stylized-concept. Asset type: transparent character sprite for original arcade boxing game. Create one full body muscular male boss boxer facing camera, three quarter frontal angle, in fighting guard with BOTH red and metallic gold boxing gloves raised at chest level, fierce expressive face, wildly swept voluminous brown hair, shirtless, athletic muscles, royal navy boxing shorts with gold waistband and gold stripes, blue and gold boxing boots. Premium polished hand-painted 3D comic video game style, strong ink contours, richly shaded skin, bright glossy leather gloves, cool arena rim lights and golden key light, similar art direction to the user's attached boxing screenshot. Entire body including hair and feet visible with 5 percent transparent margins. Character silhouette wide at shoulders. No ring, no background, no shadows outside figure, no text, no UI, no logos. Genuinely transparent background. Original fighter named Bruiser Baxter, only image no lettering.

## player-reference.png

Prompt:

> Use case: stylized-concept. Asset type: transparent player boxer sprite for original arcade boxing game. One athletic young adult male boxer shown FROM BEHIND in a three-quarter rear view, looking straight toward opponent offscreen, both bright emerald green boxing gloves raised, left glove near face and right glove out front; black short tousled hair, sleeveless dark forest green tank top showing toned shoulders and arms, green boxing trunks with broad pale silver waistband, visible full body with green boots. Crouched dynamic boxing guard stance. Premium polished hand-painted 3D comic arcade video game art like user's attached boxing screenshot, bold precise ink contours, richly shaded muscular skin, glossy bright emerald leather gloves, dramatic cool white-blue rim lighting and warm arena key light. Entire silhouette visible head to feet within image, transparent margin. Original character, no lettering, no logos, no environment, no shadows outside silhouette, no UI. Genuinely transparent background.

## Godot 3D assets

Eleven user-supplied character models are archived in [`Models`](Models/README.md): Mack, Goldie Voltage, Nico “Nightshift” Navarro, Bruiser Baxter, Atlas “Undertow” Reed, Duke Doubletake, Sylvie “Slipstream” Sloane, Cassian “Saint” Sterling, Vera Velvet, Jaison “Black Tie” Mercer, and Hunter “Redline” Mercer. Ten supplied 2D portraits are archived in [`IntroScenes`](IntroScenes/README.md) and bundled for pre-fight versus introductions. Eleven "just lost the fight" portraits, one for each character including Mack, are archived in [`DefeatedPortraits`](DefeatedPortraits/README.md) and copied unchanged into `godot/assets/portraits/`. Wins show the defeated opponent; losses show Mack. Intro and defeated portraits fit their full width and stay top-aligned, preserving at least the upper 30% without clipping faces sideways. The career finale uses Mack's existing 3D victory animation, not a new asset. See [character backstories](character-backstories.md) for story direction for all eleven characters, including the player and final boss.

The eleven supplied OBJ sculpts in `ArtDirection/Models` are the character source assets.

- **Rigs.** A headless Blender script (`scripts/blender/autorig.py`) fits each sculpt to one shared Mixamo-compatible 22-bone skeleton and computes its skin weights. The results are committed as sidecars in [`Rigs`](Rigs/README.md). `scripts/rig_fighters.py` then triangulates the OBJ, preserves vertex colors, generates smooth normals and packs the `HMR2` `.fighter` assets in `Haymaker/Models`. CI re-packs them byte for byte without Blender.
- **Animation.** The motion comes from [Mixamo](https://www.mixamo.com) boxing animations. They were downloaded on Mack's sculpt, then baked by `scripts/blender/extract_clips.py` into the shared clip library `Haymaker/Models/fighter.clips` (see [`Animations`](Animations/README.md)). Mixamo's licence lets the animations ship in a game but not be redistributed as raw files, so only the derived bake is committed. The FBX downloads stay outside the repository.
- **Runtime.** `godot/scripts/arena/fighter_assets.gd`, `fighter_animator.gd`, `fighter_pose.gd`, `fighter_director.gd` and `choreographer.gd` load the assets and play the clips on Godot skeletons. They handle cross-fades, foot planting, punch aim and fighter spacing. Existing generators stage files in `Haymaker/Models/`; copy generated runtime files into `godot/assets/models/`, without maintaining the legacy game.

The ring, lights and impact particles are Godot scene geometry in `godot/scripts/arena/arena.gd`. The crowd uses four rigged bodies in ten looks generated with the Tripo3D API; see [`Crowd`](Crowd/README.md) for the prompts' task IDs, pipeline, cost and format. All eleven story characters now have supplied source models.

The meshes use Y-up coordinates in meters, smooth vertex normals, and a mobile polygon budget. Materials are applied in the Godot scene, and animation comes from the bundled clip library. The game requires no Blender installation.

## Jaison “Black Tie” Mercer

The user supplied `jaison.obj`, `jaison.png`, and the original Jaison Elias Mercer backstory for this integration. The OBJ is archived in `Models/jaison.obj` with only its glove colours corrected (baked rim light removed; see [Models](Models/README.md)); the PNG is archived in `IntroScenes/jaison.png` and copied unchanged to `jaison-intro.imageset`. The rig is generated by the same deterministic Mixamo-skeleton pipeline as the other nine fighters. Jaison's low-poly sculpt needed a fallback when locating the glove cuffs; see `scripts/blender/autorig_joints.py`. A defeated portrait was generated from his supplied intro PNG using the built-in imagegen tool; see [DefeatedPortraits](DefeatedPortraits/README.md) for the output and exact prompt. The full supplied story is preserved in [character backstories](character-backstories.md#jaison-elias-mercer--black-tie).

## Hunter Rowan Mercer — “Redline”

User-supplied original character assets received October 19, 2026: `hunter.obj`, `hunter.png` (versus portrait), and `hunter-defeated.png` (bundled unchanged for victory results). The OBJ is rigged with the existing offline pipeline; runtime uses the generated `hunter.fighter`. No external stock assets.

## Fighter texture fidelity

All eleven fighters now have bundled base-color textures and UV seam mappings. Mack, Goldie, Atlas, Duke and Vera use their original supplied OBJ/material ZIPs. Bruiser, Hunter, Jaison, Nico, Sylvie and Cassian use derived OBJ/material ZIPs recovered from the user-supplied textured FBXs received October 21, 2026. The JPEG images are preserved byte-for-byte. Existing rig geometry and animation are unchanged. Simulator previews are captured from the actual app. No external or generated artwork was added. See [model pipeline details and FBX provenance](Models/README.md#fighter-texture-fidelity).
