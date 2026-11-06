"""Synthesize Haymaker's original punch sound effects into godot/assets/audio/.

Stdlib only and seeded, so every run writes byte-identical files:
    python3 scripts/build_punch_sfx.py           # write the WAVs
    python3 scripts/build_punch_sfx.py --check   # verify committed WAVs match

Swings are band-passed noise whose centre frequency rises and falls with the
glove's travel. Landings layer a deep pitch-dropping body thump and a short,
soft low-passed noise slap for the glove leather, without a ringing mid knock. Provenance:
ArtDirection/README.md ("Punch sound effects").
"""
import argparse
import math
import random
import struct
import sys
import wave
from pathlib import Path

RATE = 44100
PEAK = 0.89  # about -1 dBFS; per-sound mix levels are applied in Godot
OUT = Path(__file__).resolve().parent.parent / 'godot' / 'assets' / 'audio'

SWINGS = {
    'punch_swing_light': {'seed': 101, 'seconds': 0.20, 'skew': 0.70, 'low_hz': 420.0, 'sweep_hz': 1700.0,
                          'q': 0.85, 'rumble': 0.0},
    'punch_swing_heavy': {'seed': 202, 'seconds': 0.32, 'skew': 0.65, 'low_hz': 260.0, 'sweep_hz': 1050.0,
                          'q': 0.75, 'rumble': 0.45},
}

LANDINGS = {
    'punch_land_light': {'seed': 303, 'seconds': 0.26, 'thump_from': 130.0, 'thump_to': 58.0, 'glide': 0.018,
                         'thump_decay': 0.075, 'slap_decay': 0.006, 'slap_cutoff': 1900.0, 'slap': 0.40,
                         'drive': 1.0},
    'punch_land_heavy': {'seed': 404, 'seconds': 0.46, 'thump_from': 100.0, 'thump_to': 40.0, 'glide': 0.028,
                         'thump_decay': 0.17, 'slap_decay': 0.009, 'slap_cutoff': 1300.0, 'slap': 0.45,
                         'drive': 1.6},
}


def swing(seed, seconds, skew, low_hz, sweep_hz, q, rumble):
    rng = random.Random(seed)
    n = int(RATE * seconds)
    stages = [[0.0, 0.0], [0.0, 0.0]]
    rumble_state = 0.0
    out = []
    for i in range(n):
        x = (i / n) ** skew
        bell = math.sin(math.pi * x) ** 2
        f = 2.0 * math.sin(math.pi * (low_hz + sweep_hz * bell) / RATE)
        noise = rng.uniform(-1.0, 1.0)
        signal = noise
        for stage in stages:
            stage[0] += f * stage[1]
            stage[1] += f * (signal - stage[0] - q * stage[1])
            signal = stage[1]
        rumble_state += 0.02 * (noise - rumble_state)
        out.append((signal + rumble * 6.0 * rumble_state) * bell)
    return out


def landing(seed, seconds, thump_from, thump_to, glide, thump_decay, slap_decay, slap_cutoff, slap, drive):
    rng = random.Random(seed)
    n = int(RATE * seconds)
    alpha = 1.0 - math.exp(-2.0 * math.pi * slap_cutoff / RATE)
    phase = 0.0
    slap_state = 0.0
    attack = int(RATE * 0.0005)
    fade = int(RATE * 0.01)
    norm = math.tanh(drive)
    out = []
    for i in range(n):
        t = i / RATE
        phase += 2.0 * math.pi * (thump_to + (thump_from - thump_to) * math.exp(-t / glide)) / RATE
        body = math.sin(phase) * math.exp(-t / thump_decay)
        slap_state += alpha * (rng.uniform(-1.0, 1.0) - slap_state)
        leather = slap_state * math.exp(-t / slap_decay) * 3.0
        y = math.tanh(drive * (body + slap * leather)) / norm
        y *= min(1.0, i / attack) * min(1.0, (n - 1 - i) / fade)
        out.append(y)
    return out


def pcm(samples):
    peak = max(abs(s) for s in samples)
    scale = PEAK * 32767.0 / peak
    return b''.join(struct.pack('<h', max(-32768, min(32767, round(s * scale)))) for s in samples)


def render():
    sounds = {name: swing(**spec) for name, spec in SWINGS.items()}
    sounds.update({name: landing(**spec) for name, spec in LANDINGS.items()})
    return {name: pcm(samples) for name, samples in sounds.items()}


def frames(path):
    with wave.open(str(path), 'rb') as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            return None
        return w.readframes(w.getnframes())


def same(a, b):
    """Equal PCM, allowing one LSB of drift from platform libm differences."""
    if len(a) != len(b):
        return False
    return all(abs(x - y) <= 1 for (x,), (y,) in zip(struct.iter_unpack('<h', a), struct.iter_unpack('<h', b)))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true', help='verify committed files instead of writing them')
    args = parser.parse_args()
    stale = []
    for name, data in render().items():
        path = OUT / f'{name}.wav'
        if args.check:
            current = frames(path) if path.exists() else None
            if current is None or not same(current, data):
                stale.append(path.name)
            continue
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(data)
        print(f'wrote {path.relative_to(OUT.parent.parent.parent)} ({len(data) // 2 / RATE:.2f}s)')
    if stale:
        print('stale punch sounds: ' + ', '.join(stale), file=sys.stderr)
        return 1
    if args.check:
        print('punch sounds match scripts/build_punch_sfx.py')
    return 0


if __name__ == '__main__':
    sys.exit(main())
