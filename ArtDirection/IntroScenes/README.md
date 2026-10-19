# Character introduction portraits

Nine user-supplied PNG graphics are archived here as source art. Byte-for-byte copies are bundled in the app's `*-intro` image assets and shown as face close-ups in the pre-fight versus dialog. Every career bout, sparring round and rematch waits for the player to ring the bell.

| Character | Portrait | Supplied filename |
| --- | --- | --- |
| Atlas “Undertow” Reed | [atlas.png](atlas.png) | `atlas.png` |
| Bruiser Baxter | [bruiser.png](bruiser.png) | `bruiser.png` |
| Cassian “Saint” Sterling | [cassian.png](cassian.png) | `cassian.png` |
| Duke Doubletake | [duke.png](duke.png) | `duke.png` |
| Goldie Voltage | [goldie.png](goldie.png) | `goldie.png` |
| Nico “Nightshift” Navarro | [nico.png](nico.png) | `nico.png` |
| Sylvie “Slipstream” Sloane | [sylvie.png](sylvie.png) | `sylviepng.png` |
| Vera Velvet | [vera.png](vera.png) | `vera.png` |
| Jaison “Black Tie” Mercer | [jaison.png](jaison.png) | `jaison.png` |

The original eight files are 1024 × 1536 RGBA PNGs, preserved byte-for-byte from the supplied files. Only Sylvie's filename is normalized. The portraits include a dark atmospheric glow around the figures and have varying alpha (observed range 0–254); preserve that alpha when compositing and review the result against the intended scene background. They are not cropped character cutouts or sprite sheets. No Mack intro portrait was supplied in this batch.

See [character backstories](../character-backstories.md) for character motivations, fighting identities, and sample intro dialogue. These supplied files are distinct from the earlier concept reference images in the parent directory.

Jaison’s 1024 × 1536 supplied PNG is preserved byte-for-byte and bundled as `jaison-intro`. It is used with his walkout line, “Let’s get this sorted.”

## Hunter Rowan Mercer — “Redline”

User-supplied original character assets received October 19, 2026: `hunter.obj`, `hunter.png` (versus portrait), and `hunter-defeated.png` (bundled unchanged for victory results). The OBJ is rigged with the existing offline pipeline; runtime uses the generated `hunter.fighter`. No external stock assets.
