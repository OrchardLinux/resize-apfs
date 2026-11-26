"""Sign Resize APFS with the user's own Apple ID and install it, on Linux and macOS.

The app is the pinned Dopamine with Resize APFS in it (embed.py). On a Mac whose Xcode is
signed in to an Apple ID, that account signs it (xcode_signing.py): nothing new to sign in to.
Otherwise xtool (pinned in tools.py) does the Apple side: `xtool auth login` signs in once
(two-factor included) and keeps the session; `xtool install` registers the device, makes the
App ID and provisioning profile, signs the app and installs it over the cable. The App ID is
`XTL-<account>.<bundle identifier>`, the same on every signing, so re-signing every 7 days
(free accounts) reuses it instead of using up the weekly allowance of new ones. The bundle
identifiers are the ones earlier releases signed the plain Dopamine with, so the app replaces
that one in place.

Apple's sign-in needs anisette data (device identity); xtool gets it from the SideStore
project's Omnisette server, as every free sideloading tool does. The password and two-factor
code go only to Apple.

The signing record and its expiry are kept in Orchard's cache; while a signed copy of the same
app for the same device has more than a day left, nothing is signed or installed again.

Releases never contain anything team-signed: signing happens on the user's computer, with the
user's account, for the user's device.
"""
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

import embed
import tools
import xcode_signing
from image_format import require

MARGIN = datetime.timedelta(days=1)
# A free Apple ID's profiles last 7 days; a paid one's longer, so this never overstates.
VALIDITY = datetime.timedelta(days=7)
VERIFY = ('Before opening Resize APFS the first time, trust your Apple ID on the device: Settings > General > '
          'VPN & Device Management, open your Apple ID and confirm.')
ROOT = pathlib.Path(__file__).resolve().parents[1]
# The Resize APFS side of the app (scripts/build-device.sh).
PAYLOAD = ROOT / 'out/device/access'


def available(host=tools.host):
    """True when the app can be signed here: Xcode on a Mac, or an xtool release for this computer."""
    try:
        return ('xtool', *host()) in tools.PINS
    except ValueError:
        return False


def xcode_team(ask=input, run=subprocess.run):
    """(team id, name, free) of the account a Mac's Xcode is signed in to, or None (not a Mac,
    no devicectl, or no account): then xtool signs."""
    if sys.platform != 'darwin':
        return None
    try:
        if run(['xcrun', '--find', 'devicectl'], capture_output=True, timeout=30).returncode:
            return None
    except (OSError, subprocess.TimeoutExpired):
        return None
    found = xcode_signing.teams(run)
    return xcode_signing.choose_team(found, ask) if found else None


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


def payload_key(payload):
    """One hash over every file of the Resize APFS payload."""
    payload = pathlib.Path(payload)
    files = sorted(path for path in payload.rglob('*') if path.is_file())
    require(files, 'This folder has no app for the route without DFU (out/device/access). '
                   'Use the release ZIP, or build it with scripts/build-device.sh.')
    return hashlib.sha256(''.join(f'{path.relative_to(payload).as_posix()} {tools.sha256_file(path)}\n'
                                  for path in files).encode()).hexdigest()


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
    # xtool's App IDs carry a prefix (XTL-<account>.<identifier>).
    return None if apps is None else any(a.get('bundleIdentifier', '') == identifier or
                                         a.get('bundleIdentifier', '').endswith('.' + identifier) for a in apps)


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
    """The expiry of the installed app when it is this one and has over a day left, else None.
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


def install(ipa, udid, ask=input, run=subprocess.run, root=None, payload=None, provide=tools.provide,
            team=None):
    """Put Resize APFS into the Dopamine `ipa`, sign it with the user's Apple ID and install it
    on `udid` after one confirmation, unless a signed copy is still installed. `team`: Xcode's
    account (xcode_team), or None for xtool."""
    payload = PAYLOAD if payload is None else payload
    team = xcode_team(ask, run) if team is None else (team or None)
    identifier = xcode_signing.bundle_id(team[0]) if team else 'com.opa334.Dopamine'
    # The installed copy is kept only when it was made from the same Dopamine and payload, the same way.
    key = hashlib.sha256(' '.join([identifier, tools.sha256_file(ipa), payload_key(payload)]).encode()).hexdigest()
    expires = still_signed(key, udid, root=root, run=run, identifier=identifier)
    if expires:
        print(f'Resize APFS is installed and signed until {expires:%d %b %Y}.')
        return
    account = f"the Apple ID Xcode is signed in to ({team[1]})" if team else 'your Apple ID'
    ask(f'Sign Resize APFS with {account} and install it on {describe(udid, run)}. Press Enter to continue. ')
    with tempfile.TemporaryDirectory(prefix='resize-apfs-sign-') as work:
        work = pathlib.Path(work)
        prepared = embed.prepared_ipa(ipa, work / 'prepared', payload)
        if team:
            when = install_with_xcode(prepared, work / 'xcode', team[0], identifier, udid, run)
        else:
            when = install_with_xtool(prepared, udid, run, provide)
    record = record_path(udid, root)
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({'expires': when.isoformat(), 'key': key}))
    print(f'Resize APFS is installed, signed until about {when:%d %b %Y}.')
    print(VERIFY, flush=True)


def install_with_xcode(prepared, work, team, identifier, udid, run=subprocess.run):
    """Sign with Xcode's account and install with devicectl; the profile's expiry."""
    print('Making a signing profile with Xcode...', flush=True)
    profile, entitlements, sha1 = xcode_signing.provision(work / 'profile', team, udid, run)
    when = xcode_signing.expiry(profile, run)
    app = xcode_signing.resign(prepared, work / 'app', identifier, profile, entitlements, sha1, run)
    print('Installing Resize APFS...', flush=True)
    result = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', udid, str(app)],
                 capture_output=True, text=True, timeout=600)
    require(result.returncode == 0, 'Installing Resize APFS failed: ' + (result.stderr or result.stdout).strip()[-800:])
    return when


def install_with_xtool(prepared, udid, run=subprocess.run, provide=tools.provide):
    """Sign and install with xtool, signing in first when needed; the expected expiry."""
    xtool = provide('xtool')
    if not logged_in(xtool, run):
        log_in(xtool, run)
    print('Signing and installing Resize APFS...', flush=True)
    signed_at = datetime.datetime.now(datetime.timezone.utc)
    # In this terminal: xtool may ask to trust the device or to replace a certificate.
    result = run([str(xtool), 'install', '--usb', '--udid', udid, str(prepared)], env=environment())
    require(result.returncode == 0, f'Signing or installing Resize APFS failed (xtool exit status {result.returncode}).')
    return signed_at + VALIDITY
