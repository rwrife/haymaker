"""Asset contract checks: rebuild determinism, topology, weights and chin isolation."""
import math
import struct
import tempfile
import unittest
from pathlib import Path
from rig_fighters import BONES, NAMES, ROOT, build


class FighterAssetsTests(unittest.TestCase):
    def test_all_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name in NAMES:
                with self.subTest(model=name):
                    out = Path(temporary)
                    build(name, out)
                    data = (out/f'{name}.fighter').read_bytes()
                    self.assertEqual(data, (ROOT/'Haymaker'/'Models'/f'{name}.fighter').read_bytes())
                    magic, count, indices, bones = struct.unpack_from('<4sIII', data)
                    self.assertEqual(magic, b'HMR1')
                    self.assertEqual(bones, len(BONES))
                    start = 16 + bones*16
                    self.assertEqual(len(data), start+count*60+indices*4)
                    chin = 0
                    for i in range(count):
                        row = struct.unpack_from('<13f4H', data, start+i*60)
                        position, normal, color, weights, ids = row[:3], row[3:6], row[6:9], row[9:13], row[13:]
                        self.assertTrue(all(math.isfinite(v) for v in row))
                        self.assertAlmostEqual(sum(weights), 1., places=6)
                        self.assertTrue(all(0 <= w <= 1 for w in weights))
                        self.assertTrue(all(0 <= j < bones for j in ids))
                        self.assertTrue(all(0 <= c <= 1 for c in color))
                        norm = sum(n*n for n in normal)
                        self.assertTrue(norm < .0001 or abs(norm-1) < .0001)
                        # Facial vertices must never receive torso/arm influence.
                        if abs(position[0])/2.7 < .1 and position[1]/2.7 >= .84001:
                            chin += 1
                            self.assertTrue(all(j == 3 for j, w in zip(ids, weights) if w > 0))
                        # Outstretched gloves must not be assigned to the head.
                        if abs(position[0])/2.7 > .35 and position[1]/2.7 > .69:
                            self.assertTrue(all(4 <= j <= 9 for j, w in zip(ids, weights) if w > 0))
                    self.assertGreater(chin, 100)
                    topology = struct.unpack_from(f'<{indices}I', data, start+count*60)
                    self.assertLess(max(topology), count)
                    self.assertEqual(indices % 3, 0)


if __name__ == '__main__':
    unittest.main()
