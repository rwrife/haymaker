"""Verify native iPad support without the fixed-size compatibility mode."""
import json
import plistlib
import re
import sys
from pathlib import Path

IPAD_ORIENTATIONS = {
    'UIInterfaceOrientationPortrait',
    'UIInterfaceOrientationPortraitUpsideDown',
    'UIInterfaceOrientationLandscapeLeft',
    'UIInterfaceOrientationLandscapeRight',
}


def validate_app(info):
    assert sorted(info['UIDeviceFamily']) == [1, 2], 'App must support iPhone and iPad'
    assert not info.get('UIRequiresFullScreen', False), 'Do not opt into fixed-size compatibility mode'
    orientations = info.get('UISupportedInterfaceOrientations~ipad',
                            info.get('UISupportedInterfaceOrientations', []))
    assert set(orientations) == IPAD_ORIENTATIONS, 'iPad must support all four orientations'
    assert any(key in info for key in ('UILaunchScreen', 'UILaunchScreens',
                                      'UILaunchStoryboardName', 'UILaunchStoryboards')), 'Missing launch screen'


def main():
    root = Path(__file__).resolve().parent.parent
    contract = json.loads((root / 'toolchain.json').read_text())
    assert contract['targeted_device_family'] == '1,2'
    assert contract['native_ipad_support'] is True
    settings = re.findall(r'TARGETED_DEVICE_FAMILY\s*=\s*([^;]+);',
                          (root / 'Haymaker.xcodeproj/project.pbxproj').read_text())
    assert settings and all(value.strip('" ') == '1,2' for value in settings), settings
    if len(sys.argv) > 1:
        with open(sys.argv[1], 'rb') as source:
            validate_app(plistlib.load(source))
    print('Native iPhone and resizable iPad display contract: PASS')


if __name__ == '__main__':
    main()
