# Visual references and asset provenance

The user's supplied boxing screenshot is the composition and mood reference. The shipped arena and characters are 3D meshes rendered with Metal through SceneKit. These PNGs are concept references only, not runtime backgrounds, sprite sheets, or screenshot substitutes.

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

## Native 3D assets

Four user-supplied T-pose character models are archived in [`Models`](Models/README.md) for future integration: Mack, Goldie Voltage, Nico “Nightshift” Navarro, and Bruiser Baxter. See [character backstories](character-backstories.md) for their story reference, including new player and final-boss histories.

`Haymaker/Models/baxter-torso.obj` and `Haymaker/Models/boxer-head.obj` are smooth sculpted meshes authored by `scripts/build_fighter_meshes.py`, using Blender's voxel remesh, smoothing, subdivision, and decimation. Limbs, articulated joints, gloves, swept hair, clothing, boots, ring, crowd, lights and impact particles are constructed as native 3D scene geometry in `Haymaker/MatchScene.swift`.

The meshes use Y-up coordinates in meters, smooth vertex normals, and a mobile polygon budget. Materials and animation are applied in the native scene. The runtime requires no Blender installation.
