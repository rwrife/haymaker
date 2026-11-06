"""Stdlib-only punch timbre checks: python3 scripts/test_punch_sfx.py."""
import math
import struct
import unittest
import wave

import build_punch_sfx as sfx


def band_fraction(samples, low_hz, high_hz):
    """Goertzel DFT bins / Parseval energy, without an FFT dependency."""
    n = len(samples)
    power = 0.0
    for k in range(math.ceil(low_hz * n / sfx.RATE), math.ceil(high_hz * n / sfx.RATE)):
        coefficient = 2.0 * math.cos(2.0 * math.pi * k / n)
        previous = older = 0.0
        for sample in samples:
            previous, older = sample + coefficient * previous - older, previous
        power += previous * previous + older * older - coefficient * previous * older
    return 2.0 * power / (n * sum(sample * sample for sample in samples))


class PunchSounds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.samples = {}
        for name in (*sfx.SWINGS, *sfx.LANDINGS):
            data = sfx.frames(sfx.OUT / f'{name}.wav')
            if data is None:
                raise AssertionError(f'{name}: expected 44.1 kHz mono 16-bit PCM')
            cls.samples[name] = [sample / 32768.0 for (sample,) in struct.iter_unpack('<h', data)]

    def test_pcm_shape_and_headroom(self):
        for name, samples in self.samples.items():
            with self.subTest(sound=name):
                spec = (sfx.SWINGS | sfx.LANDINGS)[name]
                self.assertEqual(len(samples), int(sfx.RATE * spec['seconds']))
                self.assertEqual(samples[0], 0.0)
                self.assertEqual(samples[-1], 0.0)
                self.assertAlmostEqual(max(abs(x) for x in samples), sfx.PEAK, delta=2.0 / 32768)
                with wave.open(str(sfx.OUT / f'{name}.wav'), 'rb') as wav:
                    self.assertEqual(wav.getcomptype(), 'NONE')

    def test_landings_are_bass_weighted_not_ringing(self):
        for name, minimum_bass_rms in [('punch_land_light', 0.23), ('punch_land_heavy', 0.34)]:
            with self.subTest(sound=name):
                samples = self.samples[name]
                bass = band_fraction(samples, 35.0, 180.0)
                mid = band_fraction(samples, 250.0, 1200.0)
                rms = math.sqrt(sum(x * x for x in samples) / len(samples))
                self.assertGreaterEqual(bass, 0.95, 'at least 95% of impact energy belongs in the bass')
                self.assertLess(mid, 0.02, 'midrange knock must not ring over the thump')
                self.assertGreaterEqual(rms * math.sqrt(bass), minimum_bass_rms,
                                        'deeper impacts must retain bass weight, not just lose treble')

    def test_power_punches_still_hit_harder_than_jabs(self):
        light = self.samples['punch_land_light']
        heavy = self.samples['punch_land_heavy']
        self.assertGreater(len(heavy), len(light))
        self.assertGreater(sum(x * x for x in heavy), 2.0 * sum(x * x for x in light))


if __name__ == '__main__':
    unittest.main()
