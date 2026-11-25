"""Sign the pinned Dopamine with the user's own Apple ID and install it, on a Mac with Xcode.

Nothing here logs in to Apple: it uses the account Xcode is already signed in to
(Xcode > Settings > Accounts). Xcode makes the provisioning profile while it builds a tiny
stub app with automatic signing for the connected device; the stub's profile and
entitlements then sign Dopamine under the same bundle identifier, and `devicectl` installs it.

One identifier per team (`dev.orchard.dopamine.<team>`), so re-signing every 7 days (free
accounts) reuses the same App ID instead of using up the weekly allowance of new ones. The
signed app and its expiry are kept in Orchard's cache; while a signed copy of this Dopamine is
installed and has more than a day left, nothing is signed or installed again.

Releases never contain anything team-signed: signing happens on the user's computer, with
the user's account, for the user's device.
"""
import datetime
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import tools
from image_format import require

MACHO_MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
STUB = 'DopamineSigning'
MARGIN = datetime.timedelta(days=1)


def available(run=subprocess.run):
    """True on a Mac whose Xcode has devicectl (Xcode 15 or later)."""
    if sys.platform != 'darwin':
        return False
    try:
        return run(['xcrun', '--find', 'devicectl'], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def teams(run=subprocess.run):
    """[(team id, name, free)] of the accounts Xcode is signed in to."""
    result = run(['defaults', 'export', 'com.apple.dt.Xcode', '-'], capture_output=True, timeout=30)
    if result.returncode:
        return []
    try:
        settings = plistlib.loads(result.stdout)
    except Exception:
        return []
    found = {}
    for account in (settings.get('IDEProvisioningTeamByIdentifier') or {}).values():
        for team in account if isinstance(account, list) else []:
            if team.get('teamID'):
                found[team['teamID']] = (team['teamID'], team.get('teamName', team['teamID']),
                                         bool(team.get('isFreeProvisioningTeam')))
    return sorted(found.values())


def choose_team(found, ask=input):
    require(found, 'Xcode is not signed in to an Apple ID. Add yours in Xcode > Settings > Accounts, '
                   'then run this again.')
    if len(found) == 1:
        return found[0]
    print('Xcode is signed in to several teams. Sign Dopamine with:')
    for number, (team, name, _) in enumerate(found, 1):
        print(f'  {number}) {name} ({team})')
    answer = ask('> ').strip()
    require(answer.isdigit() and 1 <= int(answer) <= len(found), 'Please answer with one of the numbers.')
    return found[int(answer) - 1]


def bundle_id(team):
    return 'dev.orchard.dopamine.' + team.lower()


PBXPROJ = '''// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {};
	objectVersion = 56;
	objects = {
		A1000001 = {isa = PBXBuildFile; fileRef = A1000002; };
		A1000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		A1000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = @STUB@.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A1000004 = {isa = PBXGroup; children = (A1000002, A1000005); sourceTree = "<group>"; };
		A1000005 = {isa = PBXGroup; children = (A1000003); name = Products; sourceTree = "<group>"; };
		A1000006 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1000001); runOnlyForDeploymentPostprocessing = 0; };
		A1000007 = {isa = PBXNativeTarget; buildConfigurationList = A1000009; buildPhases = (A1000006); buildRules = (); dependencies = (); name = @STUB@; productName = @STUB@; productReference = A1000003; productType = "com.apple.product-type.application"; };
		A1000008 = {isa = PBXProject; buildConfigurationList = A1000011; compatibilityVersion = "Xcode 14.0"; mainGroup = A1000004; productRefGroup = A1000005; projectDirPath = ""; projectRoot = ""; targets = (A1000007); };
		A1000009 = {isa = XCConfigurationList; buildConfigurations = (A1000010); defaultConfigurationName = Debug; };
		A1000010 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {
			ALWAYS_SEARCH_USER_PATHS = NO;
			CODE_SIGN_STYLE = Automatic;
			CURRENT_PROJECT_VERSION = 1;
			DEVELOPMENT_TEAM = @TEAM@;
			GENERATE_INFOPLIST_FILE = YES;
			INFOPLIST_KEY_UILaunchScreen_Generation = YES;
			IPHONEOS_DEPLOYMENT_TARGET = 15.0;
			MARKETING_VERSION = 1.0;
			PRODUCT_BUNDLE_IDENTIFIER = "@BUNDLE@";
			PRODUCT_NAME = @STUB@;
			SDKROOT = iphoneos;
			SWIFT_VERSION = 5.0;
			TARGETED_DEVICE_FAMILY = "1,2";
		}; };
		A1000011 = {isa = XCConfigurationList; buildConfigurations = (A1000012); defaultConfigurationName = Debug; };
		A1000012 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {SDKROOT = iphoneos; }; };
	};
	rootObject = A1000008;
}
'''

SCHEME = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForRunning="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A1000007"
               BuildableName="@STUB@.app" BlueprintName="@STUB@" ReferencedContainer="container:@STUB@.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
</Scheme>
'''

MAIN = 'import UIKit\nUIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, nil)\n'


def write_stub(folder, team, identifier):
    """A one-file app project with automatic signing for `team` and `identifier`."""
    folder = pathlib.Path(folder)
    project = folder / f'{STUB}.xcodeproj'
    (project / 'xcshareddata/xcschemes').mkdir(parents=True)
    (folder / 'main.swift').write_text(MAIN)
    (project / 'project.pbxproj').write_text(
        PBXPROJ.replace('@STUB@', STUB).replace('@TEAM@', team).replace('@BUNDLE@', identifier))
    (project / f'xcshareddata/xcschemes/{STUB}.xcscheme').write_text(SCHEME.replace('@STUB@', STUB))
    return project


def stub_command(project, udid, derived):
    return ['xcodebuild', '-project', str(project), '-scheme', STUB, '-configuration', 'Debug',
            '-destination', f'id={udid}', '-derivedDataPath', str(derived),
            '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build']


def provision(work, team, udid, run=subprocess.run):
    """(profile path, entitlements plist bytes, signing identity) from the built stub."""
    work = pathlib.Path(work)
    project = write_stub(work / 'stub', team, bundle_id(team))
    log = work / 'xcodebuild.log'
    with open(log, 'wb') as stream:
        result = run(stub_command(project, udid, work / 'derived'), stdout=stream, stderr=subprocess.STDOUT, timeout=900)
    if result.returncode:
        raise ValueError('Xcode could not make a signing profile for the device.\n' + tail(log) + f'\nLog: {log}')
    app = work / f'derived/Build/Products/Debug-iphoneos/{STUB}.app'
    profile = app / 'embedded.mobileprovision'
    require(profile.is_file(), 'Xcode built the signing app without a provisioning profile.')
    entitlements = run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, timeout=60).stdout
    require(entitlements.lstrip().startswith(b'<?xml'), 'Could not read the signing entitlements.')
    details = run(['codesign', '-dvv', str(app)], capture_output=True, text=True, timeout=60).stderr
    authority = next((line.split('=', 1)[1] for line in details.splitlines() if line.startswith('Authority=')), None)
    require(authority, 'Could not find which certificate Xcode signed with.')
    return profile, entitlements, identity(authority, run)


def identity(authority, run=subprocess.run):
    """The SHA-1 of the one valid signing identity named `authority` (an expired one may share its name)."""
    listing = run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, timeout=60).stdout
    matches = re.findall(r'^\s*\d+\) ([0-9A-F]{40}) "(.*)"$', listing, re.M)
    hashes = [sha for sha, name in matches if name == authority]
    require(len(hashes) == 1, f'Expected one valid signing certificate named "{authority}", found {len(hashes)}.')
    return hashes[0]


def expiry(profile, run=subprocess.run):
    decoded = run(['security', 'cms', '-D', '-i', str(profile)], capture_output=True, timeout=60)
    require(decoded.returncode == 0, 'Could not read the provisioning profile.')
    when = plistlib.loads(decoded.stdout)['ExpirationDate']
    return when if when.tzinfo else when.replace(tzinfo=datetime.timezone.utc)


def is_macho(path):
    with open(path, 'rb') as stream:
        return stream.read(4) in MACHO_MAGIC


def sign_order(app):
    """Everything to sign inside `app`, innermost first: loose Mach-O files, then bundles."""
    app = pathlib.Path(app)
    bundles = [p for p in app.rglob('*') if p.is_dir() and p.suffix in ('.framework', '.appex', '.bundle')]
    loose = [p for p in app.rglob('*') if p.is_file() and not p.is_symlink() and is_macho(p)
             and p.parent not in bundles and p != app / plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleExecutable']]
    by_depth = lambda p: -len(p.relative_to(app).parts)
    return sorted(loose, key=by_depth) + sorted(bundles, key=by_depth)


def resign(ipa, work, identifier, profile, entitlements, sha1, run=subprocess.run):
    """Dopamine.app from `ipa`, under `identifier`, signed with the profile and identity."""
    work = pathlib.Path(work)
    with zipfile.ZipFile(ipa) as archive:
        for name in archive.namelist():
            target = (work / name).resolve()
            require(target.is_relative_to(work.resolve()), 'Unsafe path in the Dopamine IPA.')
        archive.extractall(work)
    apps = list((work / 'Payload').glob('*.app'))
    require(len(apps) == 1, 'The Dopamine IPA does not hold exactly one app.')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    info['CFBundleIdentifier'] = identifier
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copyfile(profile, app / 'embedded.mobileprovision')
    (work / 'entitlements.plist').write_bytes(entitlements)
    sign = ['codesign', '--force', '--sign', sha1, '--timestamp=none', '--generate-entitlement-der']
    for path in sign_order(app):
        result = run([*sign, str(path)], capture_output=True, text=True, timeout=300)
        require(result.returncode == 0, f'Signing {path.name} failed: {result.stderr.strip()}')
    result = run([*sign, '--entitlements', str(work / 'entitlements.plist'), str(app)], capture_output=True, text=True, timeout=300)
    require(result.returncode == 0, f'Signing Dopamine failed: {result.stderr.strip()}')
    return app


def installed(udid, identifier, run=subprocess.run):
    """True when the device has an app with `identifier`, False when not, None when unknown."""
    with tempfile.TemporaryDirectory() as folder:
        output = pathlib.Path(folder) / 'apps.json'
        try:
            result = run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', udid, '--bundle-id', identifier,
                          '--json-output', str(output)], capture_output=True, timeout=120)
            apps = json.loads(output.read_text())['result']['apps'] if result.returncode == 0 else None
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            return None
    return None if apps is None else any(a.get('bundleIdentifier') == identifier for a in apps)


def describe(udid, run=subprocess.run):
    """The device's name and model as Xcode shows them, else its UDID: the confirmation names
    the device so a wrong one connected is noticed before anything is installed on it."""
    with tempfile.TemporaryDirectory() as folder:
        output = pathlib.Path(folder) / 'device.json'
        try:
            run(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', udid, '--json-output', str(output)],
                capture_output=True, timeout=120)
            result = json.loads(output.read_text())['result']
            name = result['deviceProperties']['name']
            model = result['hardwareProperties'].get('marketingName') or result['hardwareProperties'].get('productType')
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            return udid
    return f'{name} ({model})' if model else name


def record_path(identifier, root=None):
    return (root or tools.cache_root()) / 'sideload' / (identifier + '.json')


def still_signed(identifier, ipa_sha256, udid, now=None, root=None, run=subprocess.run):
    """The expiry of the installed Dopamine when it is this release and has over a day left, else None."""
    try:
        record = json.loads(record_path(identifier, root).read_text())
        expires = datetime.datetime.fromisoformat(record['expires'])
        if record['ipa'] != ipa_sha256 or record['device'] != udid:
            return None
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if expires - MARGIN <= (now or datetime.datetime.now(datetime.timezone.utc)):
        return None
    return expires if installed(udid, identifier, run) else None


def install(ipa, udid, ask=input, run=subprocess.run, root=None):
    """Sign `ipa` with Xcode's account and install it on `udid` after one confirmation, unless
    a signed copy is still installed."""
    found = teams(run)
    team, name, free = choose_team(found, ask)
    identifier = bundle_id(team)
    ipa_sha256 = tools.sha256_file(ipa)
    expires = still_signed(identifier, ipa_sha256, udid, root=root, run=run)
    if expires:
        print(f'Dopamine is installed and signed until {expires:%d %b %Y}.')
        return
    ask(f'Sign Dopamine with your Apple ID ({name}) and install it on {describe(udid, run)}. '
        f'Press Enter to continue. ')
    with tempfile.TemporaryDirectory(prefix='dopamine-sign-') as work:
        print('Making a signing profile with Xcode...', flush=True)
        profile, entitlements, sha1 = provision(pathlib.Path(work) / 'profile', team, udid, run)
        when = expiry(profile, run)
        app = resign(ipa, pathlib.Path(work) / 'app', identifier, profile, entitlements, sha1, run)
        print('Installing Dopamine...', flush=True)
        result = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', udid, str(app)],
                     capture_output=True, text=True, timeout=600)
        require(result.returncode == 0, 'Installing Dopamine failed: ' + (result.stderr or result.stdout).strip()[-800:])
    record = record_path(identifier, root)
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({'expires': when.isoformat(), 'ipa': ipa_sha256, 'device': udid}))
    print(f'Dopamine is installed, signed until {when:%d %b %Y}' + (' (free Apple ID: 7 days).' if free else '.'))


def tail(log, lines=8):
    try:
        text = pathlib.Path(log).read_bytes().decode(errors='replace')
    except OSError:
        return ''
    return '\n'.join('  ' + line for line in text.strip().splitlines()[-lines:])
