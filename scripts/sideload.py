"""Sign the pinned Dopamine with the user's own Apple ID and install it, on Linux and macOS.

xtool (pinned in tools.py) does the Apple side: `xtool auth login` signs in once (two-factor
included) and keeps the session; `xtool install` registers the device, makes the App ID and
provisioning profile, signs the app and installs it over the cable. The App ID is
`XTL-<account>.<bundle identifier>`, the same on every signing, so re-signing every 7 days
(free accounts) reuses it instead of using up the weekly allowance of new ones.

Apple's sign-in needs anisette data (device identity); xtool gets it from the SideStore
project's Omnisette server, as every free sideloading tool does. The password and two-factor
code go only to Apple.

Before signing, Dopamine's bundled bootstraps are replaced by Procursus's with OpenSSH, which
the session needs (Device/README.md). The signing record and its expiry are kept in Orchard's
cache; while a signed copy of the same Dopamine for the same device has more than a day left,
nothing is signed or installed again.

Releases never contain anything team-signed: signing happens on the user's computer, with the
user's account, for the user's device.
"""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

import tools
from image_format import require

MARGIN = datetime.timedelta(days=1)
# A free Apple ID's profiles last 7 days; a paid one's longer, so this never overstates.
VALIDITY = datetime.timedelta(days=7)
VERIFY = ('Before opening Dopamine the first time, trust your Apple ID on the device: Settings > General > '
          'VPN & Device Management, open your Apple ID and confirm.')


def available(host=tools.host):
    """True when xtool has a release for this computer."""
    try:
        return ('xtool', *host()) in tools.PINS
    except ValueError:
        return False


def environment():
    """xtool's command line: the macOS app starts its interface without XTL_CLI; the AppImage
    runs without FUSE when it unpacks itself."""
    return {**os.environ, 'XTL_CLI': '1', 'APPIMAGE_EXTRACT_AND_RUN': '1'}


def logged_in(xtool, run=subprocess.run):
    result = run([str(xtool), 'auth', 'status'], capture_output=True, text=True, env=environment(), timeout=120)
    return result.returncode == 0 and result.stdout.startswith('Logged in')


def log_in(xtool, run=subprocess.run):
    """xtool's own sign-in, in this terminal: Apple ID, password, then the two-factor code."""
    print('Sign in with your Apple ID. xtool keeps the session for later runs.', flush=True)
    result = run([str(xtool), 'auth', 'login', '--mode', 'password'], env=environment())
    require(result.returncode == 0, 'Signing in to your Apple ID failed.')


def bootstraps(provide=tools.provide):
    """{version: path} of the pinned Procursus bootstraps with OpenSSH."""
    return {version: provide('bootstrap-ssh-' + version) for version in tools.BOOTSTRAP_SSH}


def swap_bootstraps(app, replacements):
    """Replace Dopamine's bundled bootstraps (bootstrap_<version>.tar.zst, unpacked on a device's
    first jailbreak) with the ones that also hold OpenSSH."""
    bundled = sorted(pathlib.Path(app).glob('bootstrap_*.tar.zst'))
    require(bundled, 'This Dopamine bundles no bootstrap.')
    for path in bundled:
        version = path.name[len('bootstrap_'):-len('.tar.zst')]
        require(version in replacements, f'No bootstrap with OpenSSH is pinned for version {version}.')
        shutil.copyfile(replacements[version], path)


def prepared_ipa(ipa, work, replacements):
    """A copy of `ipa` whose bootstraps hold OpenSSH, for xtool to sign."""
    work = pathlib.Path(work)
    unpacked = work / 'unpacked'
    with zipfile.ZipFile(ipa) as archive:
        for info in archive.infolist():
            target = (unpacked / info.filename).resolve()
            require(target.is_relative_to(unpacked.resolve()), 'Unsafe path in the Dopamine IPA.')
        archive.extractall(unpacked)
        modes = {info.filename: info.external_attr >> 16 for info in archive.infolist()}
    apps = list((unpacked / 'Payload').glob('*.app'))
    require(len(apps) == 1, 'The Dopamine IPA does not hold exactly one app.')
    swap_bootstraps(apps[0], replacements)
    output = work / 'Dopamine.ipa'
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(unpacked.rglob('*')):
            name = path.relative_to(unpacked).as_posix() + ('/' if path.is_dir() else '')
            info = zipfile.ZipInfo.from_file(path, name)
            # Keep the original modes: executables must stay executable after signing.
            info.external_attr = (modes.get(name) or (0o755 if path.is_dir() else 0o644)) << 16
            if path.is_dir():
                archive.writestr(info, b'')
            else:
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes())
    return output


def installed(udid, identifier, run=subprocess.run):
    """True when the device has an app with `identifier` (after xtool's App ID prefix), False
    when not, None when unknown (only a Mac with Xcode's devicectl can ask)."""
    if sys.platform != 'darwin':
        return None
    with tempfile.TemporaryDirectory() as folder:
        output = pathlib.Path(folder) / 'apps.json'
        try:
            result = run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', udid,
                          '--json-output', str(output)], capture_output=True, timeout=120)
            apps = json.loads(output.read_text())['result']['apps'] if result.returncode == 0 else None
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            return None
    return None if apps is None else any(a.get('bundleIdentifier', '').endswith('.' + identifier) for a in apps)


def describe(udid, run=subprocess.run):
    """The device's name and model where a Mac's devicectl can tell, else its UDID: the
    confirmation names the device, so a wrong one connected is noticed before anything is
    installed on it."""
    if sys.platform != 'darwin':
        return udid
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


def record_path(udid, root=None):
    return (root or tools.cache_root()) / 'sideload' / f'dopamine-{udid}.json'


def still_signed(key, udid, now=None, root=None, run=subprocess.run, identifier='com.opa334.Dopamine'):
    """The expiry of the installed Dopamine when it is this one and has over a day left, else None.
    Where the device cannot be asked whether it is still installed, the record decides."""
    try:
        record = json.loads(record_path(udid, root).read_text())
        expires = datetime.datetime.fromisoformat(record['expires'])
        if record['key'] != key:
            return None
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if expires - MARGIN <= (now or datetime.datetime.now(datetime.timezone.utc)):
        return None
    return None if installed(udid, identifier, run) is False else expires


def install(ipa, udid, ask=input, run=subprocess.run, root=None, replacements=None, provide=tools.provide):
    """Sign `ipa` with the user's Apple ID and install it on `udid` after one confirmation,
    unless a signed copy is still installed."""
    replacements = bootstraps(provide) if replacements is None else replacements
    # The installed copy is kept only when it was made from the same IPA and bootstraps.
    key = hashlib.sha256(' '.join([tools.sha256_file(ipa)] + [tools.sha256_file(replacements[v])
                         for v in sorted(replacements)]).encode()).hexdigest()
    expires = still_signed(key, udid, root=root, run=run)
    if expires:
        print(f'Dopamine is installed and signed until {expires:%d %b %Y}.')
        return
    ask(f'Sign Dopamine with your Apple ID and install it on {describe(udid, run)}. Press Enter to continue. ')
    xtool = provide('xtool')
    if not logged_in(xtool, run):
        log_in(xtool, run)
    with tempfile.TemporaryDirectory(prefix='dopamine-sign-') as work:
        prepared = prepared_ipa(ipa, work, replacements)
        print('Signing and installing Dopamine...', flush=True)
        signed_at = datetime.datetime.now(datetime.timezone.utc)
        # In this terminal: xtool may ask to trust the device or to replace a certificate.
        result = run([str(xtool), 'install', '--usb', '--udid', udid, str(prepared)], env=environment())
        require(result.returncode == 0, f'Signing or installing Dopamine failed (xtool exit status {result.returncode}).')
    when = signed_at + VALIDITY
    record = record_path(udid, root)
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({'expires': when.isoformat(), 'key': key}))
    print(f'Dopamine is installed, signed until about {when:%d %b %Y}.')
    print(VERIFY, flush=True)
