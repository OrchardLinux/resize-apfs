import datetime
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import xcode_signing  # noqa: E402

MACHO = b'\xcf\xfa\xed\xfe' + b'\0' * 12


def done(stdout=b'', stderr=b'', code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class TeamTests(unittest.TestCase):
    def test_teams_come_from_xcodes_accounts(self):
        settings = plistlib.dumps({'IDEProvisioningTeamByIdentifier': {'acct': [
            {'teamID': 'ABCDE12345', 'teamName': 'Someone (Personal Team)', 'isFreeProvisioningTeam': True}]}})
        self.assertEqual(xcode_signing.teams(lambda *a, **k: done(settings)), [('ABCDE12345', 'Someone (Personal Team)', True)])

    def test_no_account_says_how_to_add_one(self):
        with self.assertRaisesRegex(ValueError, 'Xcode > Settings > Accounts'):
            xcode_signing.choose_team([])

    def test_one_team_is_used_without_asking(self):
        team = ('ABCDE12345', 'Someone', True)
        self.assertEqual(xcode_signing.choose_team([team], ask=lambda p: self.fail('asked')), team)

    def test_one_bundle_identifier_per_team(self):
        self.assertEqual(xcode_signing.bundle_id('ABCDE12345'), 'org.orchardlinux.resize-apfs.abcde12345')


class StubTests(unittest.TestCase):
    def test_the_stub_project_names_team_and_identifier(self):
        with tempfile.TemporaryDirectory() as folder:
            project = xcode_signing.write_stub(folder, 'ABCDE12345', 'org.orchardlinux.resize-apfs.abcde12345')
            text = (project / 'project.pbxproj').read_text()
            scheme = next((project / 'xcshareddata/xcschemes').iterdir()).read_text()
        self.assertIn('DEVELOPMENT_TEAM = ABCDE12345;', text)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "org.orchardlinux.resize-apfs.abcde12345";', text)
        self.assertNotIn('@', text.replace('// !$*UTF8*$!', ''))
        self.assertNotIn('@', scheme)

    def test_xcode_may_register_the_device_and_update_profiles(self):
        command = xcode_signing.stub_command(pathlib.Path('p.xcodeproj'), 'UDID', pathlib.Path('d'))
        self.assertIn('-allowProvisioningUpdates', command)
        self.assertIn('-allowProvisioningDeviceRegistration', command)
        self.assertIn('id=UDID', command)

    def test_the_valid_identity_is_picked_over_an_expired_one_with_its_name(self):
        listing = ('  1) ' + 'A' * 40 + ' "Apple Development: x (Y)"\n     1 valid identities found\n')
        self.assertEqual(xcode_signing.identity('Apple Development: x (Y)', lambda *a, **k: done(listing, '')), 'A' * 40)


class SignOrderTests(unittest.TestCase):
    def test_nested_code_is_signed_before_its_bundle_and_the_main_executable_last(self):
        with tempfile.TemporaryDirectory() as folder:
            app = pathlib.Path(folder) / 'Dopamine.app'
            (app / 'Frameworks/kfd.framework').mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Dopamine'}))
            (app / 'Dopamine').write_bytes(MACHO)
            (app / 'libjailbreak.dylib').write_bytes(MACHO)
            (app / 'basebin.tar').write_bytes(b'not code')
            (app / 'Frameworks/kfd.framework/kfd').write_bytes(MACHO)
            order = [p.relative_to(app).as_posix() for p in xcode_signing.sign_order(app)]
        self.assertEqual(order, ['libjailbreak.dylib', 'Frameworks/kfd.framework'])



if __name__ == '__main__':
    unittest.main()
