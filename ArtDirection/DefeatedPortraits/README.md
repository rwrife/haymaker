# Defeated character portraits

Nine AI-generated "just lost the fight" portraits for future loss and knockout cut scenes. Each one is an image edit of that character's existing reference art, so the face, hair, costume colors, gloves, framing and art style carry over. Only the condition and pose change: slumped posture, lowered gloves, swollen eye, split lip, bruising, light blood and scuffed gear. The tone is stylized and not graphic. Each character is isolated on a fully transparent background, so the portrait can be placed directly over any scene. These are source art outside the app's resource directory; no cut-scene behavior is implemented by this addition.

| Character | Portrait | Edited from |
| --- | --- | --- |
| Mack, the player | [mack-defeated.png](mack-defeated.png) | [`../player-reference.png`](../player-reference.png) |
| Goldie Voltage | [goldie-defeated.png](goldie-defeated.png) | [`../IntroScenes/goldie.png`](../IntroScenes/goldie.png) |
| Nico “Nightshift” Navarro | [nico-defeated.png](nico-defeated.png) | [`../IntroScenes/nico.png`](../IntroScenes/nico.png) |
| Atlas “Undertow” Reed | [atlas-defeated.png](atlas-defeated.png) | [`../IntroScenes/atlas.png`](../IntroScenes/atlas.png) |
| Vera Velvet | [vera-defeated.png](vera-defeated.png) | [`../IntroScenes/vera.png`](../IntroScenes/vera.png) |
| Duke Doubletake | [duke-defeated.png](duke-defeated.png) | [`../IntroScenes/duke.png`](../IntroScenes/duke.png) |
| Sylvie “Slipstream” Sloane | [sylvie-defeated.png](sylvie-defeated.png) | [`../IntroScenes/sylvie.png`](../IntroScenes/sylvie.png) |
| Cassian “Saint” Sterling | [cassian-defeated.png](cassian-defeated.png) | [`../IntroScenes/cassian.png`](../IntroScenes/cassian.png) |
| Bruiser Baxter, the final boss | [bruiser-defeated.png](bruiser-defeated.png) | [`../IntroScenes/bruiser.png`](../IntroScenes/bruiser.png) |

## Provenance

- Generated with OpenAI's Images edit endpoint (`gpt-image-2.5-sunburst`, high quality, 1024 × 1536, `background="transparent"`) through `images.edit`, using the source image listed above as the input. No stock or external art is used.
- Prompt (shared across all nine, with an extra Mack-specific sentence):

> Edit this exact character into a 'just lost the fight' cut-scene version. Keep the SAME character identity, face, hairstyle, body type, costume colors, gloves, shorts, boots, art style, rendering and lighting palette, camera angle and full-body framing. Change only their condition and pose: they are beaten and exhausted after a boxing defeat. Slumped, hunched posture, head hanging, knees buckling, gloves lowered and drooping, heavy breathing, one eye swollen shut, split lip, bruises on face and torso, a small trickle of blood from the nose, sweat sheen, slightly disheveled hair, scuffed and rumpled costume, loosened glove laces. Teen-rated comic-arcade tone: stylized and not gory. Remove the background entirely: output the character as a clean sprite on a FULLY TRANSPARENT background, no dark backdrop, no glow, no gradient, no shadow or floor contact, fully opaque character edges. No text, no watermark, no logos, no other people.

- Mack's edit adds: keep the rear three-quarter view, with the head turned slightly so the swollen cheek shows, and keep his green tank, gloves, trunks and boots, tan skin and black tousled hair.

## Format and review notes

- All nine files are 1024 × 1536 RGBA PNGs with the background removed: every fully transparent pixel (54–65 percent of each canvas, all four corners) sits outside the figure, so each portrait composites directly onto any scene background. The intro portraits they were edited from keep their atmospheric glow, which these files drop.
- Edge quality: figures retain their ink outlines plus a thin dark fringe where the old glow met the silhouette. The outline is part of the art style, so it was left alone; matte it further if a given scene shows a halo.
- Transparent PNGs carry residual RGB values behind the alpha channel. They should not show through in normal compositing, but premultiply or flatten if a shader renders dark fringing.
- Visual checks found no text or watermarks, no extra limbs and no exposed-tissue gore. Each reads as a defeated boxer, though the poses are not exactly the originals' (they are slumped, not guarding).
- Mack's source is a rear three-quarter view, unlike the others' frontal portraits. His image keeps that view, so it will look different from the rest of the set.
- Vera has no 3D model in the repository, but her portrait is included.
- Generated art may differ slightly from the originals in small costume details such as emblems, laces and trim. Review each portrait in context before use in a cut scene.

See [character backstories](../character-backstories.md) for each character's story and fighting identity, and [IntroScenes](../IntroScenes/README.md) for the original intro portraits.
