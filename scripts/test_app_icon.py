"""Check source icon and Xcode's universal app-icon entry without image libraries."""
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'AppStore/icon.png').read_bytes()
catalog = ROOT / 'Haymaker/Assets.xcassets/AppIcon.appiconset'
assert source == (catalog / 'AppIcon.png').read_bytes(), 'App Store and Xcode artwork differ'
assert source[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
assert source[12:16] == b'IHDR', 'missing PNG header'
width, height, depth, color = struct.unpack('>IIBB', source[16:26])
assert (width, height, depth, color) == (1024, 1024, 8, 2), 'icon must be square opaque 8-bit RGB'
assert b'tRNS' not in source, 'unexpected PNG transparency chunk'
entry, = json.loads((catalog / 'Contents.json').read_text())['images']
assert entry == {'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
print('App Store and Xcode icon: matching 1024x1024 opaque RGB PNG, universal catalog entry: PASS')
