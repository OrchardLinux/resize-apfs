"""Resize APFS without DFU: Dopamine, then the app copied in over SSH for one session.

Dopamine (A8 to A13 on iOS 15.0-18.7.1 and 26.0-26.0.1, A14 and later on iOS 15.0-17.3.1) is an
app the user sideloads and starts on the device; no bootrom exploit, no DFU. Its bootstrap
(Procursus `bootstrap-ssh`, bundled in the app) brings OpenSSH, which Dopamine starts with its
other launch daemons after every jailbreak. Root logins have no password there, so the session
logs in as `mobile` (password `alpine` unless the user changed it in Dopamine's settings) and
runs each command as root through Procursus's sudo.

Dopamine trusts every program it sees started, so our ad-hoc signed iOS 15+ app and helper
(out/device, the palera1n route's payload) run as they are. Install, helper and cleanup are
the checkra1n route's (checkra1n_route.py), with one difference: iOS 15 and later starts apps
only from inside the jailbreak root, so the app goes to its Applications folder; the helper
stays in the session folder on the data partition.

Before the jailbreak, the user confirms Developer Mode is on. On a Mac, the launcher then signs
the pinned Dopamine IPA with the Apple ID Xcode is signed in to and installs it, after one
confirmation (sideload.py); elsewhere it asks the user to sign and install it themselves.
"""
import getpass
import pathlib
import tempfile

import checkra1n_route
import sideload
import usbmux
from image_format import require

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / 'out/device'
SSH_PORT = 22
USER = 'mobile'
PASSWORD = 'alpine'
JBROOT = '/var/jb'
SUDO = JBROOT + '/usr/bin/sudo'
SHELL = JBROOT + '/bin/sh'
# Stock iOS has no mkdir, cat, chmod, rm, kill or sleep; the bootstrap has them under /var/jb.
PATH = ':'.join([JBROOT + p for p in ('/usr/bin', '/bin', '/usr/sbin', '/sbin')] +
                ['/usr/bin', '/bin', '/usr/sbin', '/sbin'])
SERVER = "Dopamine's SSH server"
HINT = (SERVER + ' did not answer: {}. Unlock the device and open Dopamine: if it offers Jailbreak, '
        'tap it and run this again. A device first jailbroken with another copy of Dopamine has no SSH '
        'server: install OpenSSH from Sileo or Zebra once.')

DEVELOPER_MODE = ('Turn on Developer Mode on the device: Settings > Privacy & Security > Developer Mode, '
                  'then restart it and confirm "Turn On".\n'
                  'Press Enter when Developer Mode is on. ')
# Without Xcode (Linux): the user signs and installs it with a tool of their own.
SIGN = ('Sign Dopamine with your Apple ID and install it on the device, with Xcode, Sideloadly, '
        'AltStore or another sideloading tool. The app:\n'
        '  {}\n'
        'A free Apple ID signs it for 7 days; sign it again when it stops opening.\n'
        'Press Enter when Dopamine is on the device. ')
JAILBREAK = ('Open Dopamine on the device and tap Jailbreak. The device restarts its home screen; '
             'then unlock it.')


def device(devices=usbmux.devices):
    """The UDID of the one iOS device connected over USB."""
    found = devices()
    require(found, 'No iOS device is connected over USB. Connect the device, unlock it and trust this computer.')
    require(len(found) == 1, 'More than one iOS device is connected. Connect only the device to resize.')
    return found[0][1]


def prepare(ipa, ask=input, signer=sideload, devices=usbmux.devices):
    """The steps on the device before the session, each confirmed by the user."""
    ask(DEVELOPER_MODE)
    if signer.available():
        signer.install(ipa, device(devices), ask)
    else:
        ask(SIGN.format(ipa))
    print(JAILBREAK, flush=True)


def session_for(work, password, udid=None, run=None):
    extra = {'run': run} if run else {}
    return checkra1n_route.Session(work, udid, port=SSH_PORT, user=USER, password=password, sudo=SUDO,
                                   shell=SHELL, path=PATH, server=SERVER, **extra)


def connect(work, secret=getpass.getpass, open_session=None):
    """An open session: with Dopamine's default password, else the one the user set."""
    open_session = open_session or (lambda password: session_for(work, password))
    session = open_session(PASSWORD)
    try:
        session.open()
        return session
    except ValueError as error:
        if 'Permission denied' not in str(error):
            raise
        print(f'The device did not accept the default password for "{USER}".')
    password = secret(f'Password of "{USER}" on the device (set in Dopamine\'s settings): ')
    require(password, 'No password given.')
    session = open_session(password)
    session.open()
    return session


def app_path(session):
    """Where the app goes: the jailbreak root's Applications folder, as the kernel reports it.
    iOS 15 and later starts apps only from inside the jailbreak root."""
    real = session.sh(f'realpath {JBROOT}', 'Finding the jailbreak root').stdout
    real = (real.decode() if isinstance(real, bytes) else real).strip()
    require(real.startswith('/') and '\n' not in real and ' ' not in real, f'Unexpected jailbreak root: {real!r}')
    return real + '/Applications/ResizeAPFS.app'


def ssh_problem(udid=None, connect=None):
    return checkra1n_route.ssh_problem(udid, connect, port=SSH_PORT)


def run(ipa, ask=input):
    app, helper = checkra1n_route.payload(PAYLOAD, 'This folder has no iOS 15+ app (out/device). '
                                          'Use the release ZIP, or build it with scripts/build-device.sh.')
    prepare(ipa, ask)
    checkra1n_route.wait_for_ssh(timeout=900, problem=ssh_problem,
                                 waiting=f'Waiting for {SERVER}...', hint=HINT)
    # A short folder: the SSH control socket's path must stay under 104 bytes.
    with tempfile.TemporaryDirectory(prefix='resize-apfs-', dir='/tmp') as work:
        session = connect(work)
        try:
            target = app_path(session)
            checkra1n_route.remove_leftovers(session, target)
            checkra1n_route.install(session, app, helper, target)
            checkra1n_route.start_helper(session, target)
            checkra1n_route.leave(session, ask, app_path=target)
            print('Removed.')
        finally:
            session.close()
