"""Regression checks for built-app declarations that can cause iPad compatibility sizing."""
import unittest

from check_device_families import IPAD_ORIENTATIONS, validate_app


class DisplayContractTests(unittest.TestCase):
    def setUp(self):
        self.info = {
            'UIDeviceFamily': [1, 2],
            'UISupportedInterfaceOrientations~ipad': list(IPAD_ORIENTATIONS),
            'UILaunchScreen': {},
        }

    def test_accepts_native_resizable_ipad(self):
        validate_app(self.info)

    def test_rejects_iphone_compatibility_bundle(self):
        self.info['UIDeviceFamily'] = [1]
        with self.assertRaisesRegex(AssertionError, 'iPhone and iPad'):
            validate_app(self.info)

    def test_rejects_fixed_size_compatibility_mode(self):
        self.info['UIRequiresFullScreen'] = True
        with self.assertRaisesRegex(AssertionError, 'compatibility mode'):
            validate_app(self.info)

    def test_rejects_missing_ipad_orientation(self):
        self.info['UISupportedInterfaceOrientations~ipad'].remove('UIInterfaceOrientationPortraitUpsideDown')
        with self.assertRaisesRegex(AssertionError, 'four orientations'):
            validate_app(self.info)

    def test_rejects_missing_launch_screen(self):
        del self.info['UILaunchScreen']
        with self.assertRaisesRegex(AssertionError, 'launch screen'):
            validate_app(self.info)

    def test_accepts_shared_orientations_and_storyboard(self):
        self.info['UISupportedInterfaceOrientations'] = self.info.pop('UISupportedInterfaceOrientations~ipad')
        del self.info['UILaunchScreen']
        self.info['UILaunchStoryboardName'] = 'LaunchScreen'
        validate_app(self.info)


if __name__ == '__main__':
    unittest.main()
