"""Keep the explicitly authorized universal app contract consistent."""
import json
import plistlib
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
contract = json.loads((root / 'toolchain.json').read_text())
assert contract['targeted_device_family'] == '1,2'
assert contract['native_ipad_support'] is True
settings = re.findall(r'TARGETED_DEVICE_FAMILY\s*=\s*([^;]+);',
                      (root / 'Haymaker.xcodeproj/project.pbxproj').read_text())
assert settings and all(value.strip('" ') == '1,2' for value in settings), settings
if len(sys.argv) > 1:
    with open(sys.argv[1], 'rb') as source:
        families = plistlib.load(source)['UIDeviceFamily']
    assert sorted(families) == [1, 2], families
print('iPhone and iPad device families: PASS')
