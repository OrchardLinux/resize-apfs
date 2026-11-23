"""Resize APFS on iOS 12-14: checkra1n, then the app copied in over SSH for one session.

checkra1n has no overlay for our files, but every checkra1n boot starts an SSH server
(dropbear, port 44, root) inside iOS. Over the USB cable (usbmuxd, see usbmux.py) one SSH
connection then:

  1. removes what an interrupted earlier session left behind,
  2. copies the app to /Applications and the helper to /var/root/ResizeAPFS/session,
  3. has the helper register the app with the home screen,
  4. runs the helper as root while the user resizes in the app,
  5. after the user is done: stops the helper, unregisters and deletes the app.

Only `sh`, `mkdir`, `cat`, `chmod`, `rm` and `kill` are used on the device; registering the app
is our helper's job, so nothing depends on other tools in checkra1n's package. The helper's
operation journal under /var/root/Library/ResizeAPFS stays, as on the palera1n route.
"""
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

import boot_run
import usbmux
from image_format import require

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / 'out/device-ios12'
APP = '/Applications/ResizeAPFS.app'
SESSION = '/var/root/ResizeAPFS/session'
# checkra1n's last line once the device is booting.
CHECKRA1N_DONE = 'All Done'
HELPER = SESSION + '/resize-helper'
PIDFILE = SESSION + '/helper.pid'
SSH_PORT = 44
# checkra1n's SSH server accepts root with iOS's default password.
PASSWORD = 'alpine'


def payload(root=PAYLOAD):
    app, helper = root / 'ResizeAPFS.app', root / 'resize-helper'
    require(app.is_dir() and helper.is_file(),
            'This release has no iOS 12-14 app yet (out/device-ios12). Use the iOS 15+ route or a newer release.')
    return app, helper


class Session:
    """One SSH connection to checkra1n's server, reused for every command (ControlMaster)."""

    def __init__(self, work, udid=None, run=subprocess.run):
        self.work = pathlib.Path(work)
        self.run_process = run
        askpass = self.work / 'askpass'
        askpass.write_text(f'#!/bin/sh\necho {PASSWORD}\n')
        askpass.chmod(0o700)
        proxy = shlex.join([sys.executable, str(ROOT / 'scripts/usbmux.py'), 'proxy', str(SSH_PORT), *([udid] if udid else [])])
        self.env = {**os.environ, 'SSH_ASKPASS': str(askpass), 'SSH_ASKPASS_REQUIRE': 'force', 'DISPLAY': os.environ.get('DISPLAY', ':0')}
        self.base = ['ssh', '-T',
                     '-o', 'ProxyCommand=' + proxy,
                     '-o', 'ControlPath=' + str(self.work / 'ssh.sock'),
                     '-o', 'PreferredAuthentications=password,keyboard-interactive',
                     '-o', 'PubkeyAuthentication=no',
                     # Each checkra1n boot may present a new host key; nothing is saved.
                     '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                     '-o', 'LogLevel=ERROR', '-o', 'ServerAliveInterval=15', '-o', 'ConnectTimeout=20',
                     'root@iphone']

    def open(self):
        result = self.run_process([*self.base[:2], '-o', 'ControlMaster=yes', '-o', 'ControlPersist=yes', '-N', '-f',
                                   *self.base[2:]], env=self.env, capture_output=True, text=True, timeout=60)
        require(result.returncode == 0, "checkra1n's SSH server did not accept the connection: " + result.stderr.strip())

    def close(self):
        self.run_process([*self.base, '-O', 'exit'], env=self.env, capture_output=True, timeout=30)

    def sh(self, script, what, stdin=None, check=True):
        result = self.run_process([*self.base, script], env=self.env, input=stdin, capture_output=True, timeout=300)
        if check:
            detail = result.stderr.decode(errors='replace').strip() if isinstance(result.stderr, bytes) else (result.stderr or '').strip()
            require(result.returncode == 0, f'{what} failed on the device' + (f': {detail}' if detail else '.'))
        return result

    def put_file(self, local, remote, mode):
        self.sh(f'cat > {shlex.quote(remote)} && chmod {mode:o} {shlex.quote(remote)}',
                f'Copying {pathlib.PurePath(remote).name}', stdin=pathlib.Path(local).read_bytes())

    def put_tree(self, local, remote):
        local = pathlib.Path(local)
        directories = [remote] + [remote + '/' + p.relative_to(local).as_posix() for p in sorted(local.rglob('*')) if p.is_dir()]
        self.sh('mkdir -p ' + ' '.join(shlex.quote(d) for d in directories), 'Creating the app folder')
        for path in sorted(local.rglob('*')):
            require(not path.is_symlink(), f'The app must not contain links: {path}')
            if path.is_file():
                mode = 0o755 if os.access(path, os.X_OK) or is_macho(path) else 0o644
                self.put_file(path, remote + '/' + path.relative_to(local).as_posix(), mode)


MACHO_MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}


def is_macho(path):
    """Executables and libraries: a release ZIP built from CI artifacts loses execute bits."""
    with open(path, 'rb') as stream:
        return stream.read(4) in MACHO_MAGIC


def remove_leftovers(session):
    """Undo an earlier session that ended before its cleanup. Safe when there is none."""
    session.sh(f'if [ -f {PIDFILE} ]; then kill "$(cat {PIDFILE})" 2>/dev/null; rm -f {PIDFILE}; fi; '
               f'if [ -x {HELPER} ] && [ -d {APP} ]; then {HELPER} --unregister-app {APP}; fi; '
               f'rm -rf {APP} {SESSION}', 'Removing an earlier session')


def install(session, app, helper):
    session.sh(f'mkdir -p {SESSION}', 'Preparing the session folder')
    session.put_file(helper, HELPER, 0o755)
    session.put_tree(app, APP)
    session.sh(f'{HELPER} --register-app {APP}', 'Adding the app to the home screen')


def start_helper(session, popen=subprocess.Popen):
    """The helper as root for this session; its process id goes to PIDFILE (exec keeps $$)."""
    log = open(session.work / 'helper.log', 'wb')
    return popen([*session.base, f'echo $$ > {PIDFILE}; exec {HELPER} --session --allow-writes --ui-path {APP}/ResizeAPFS'],
                 env=session.env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)


def busy(session):
    """True while a resize the helper started is still running."""
    return session.sh(f'{HELPER} --operation-active', 'Asking the helper', check=False).returncode == 0


def finish(session, helper_process):
    session.sh(f'if [ -f {PIDFILE} ]; then kill "$(cat {PIDFILE})" 2>/dev/null; rm -f {PIDFILE}; fi', 'Stopping the helper', check=False)
    try:
        helper_process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        helper_process.kill()
    session.sh(f'{HELPER} --unregister-app {APP}; rm -rf {APP} {SESSION}', 'Removing the app')


def checkra1n_command(executable, run=subprocess.run):
    command = [str(executable), '--cli']
    if sys.platform == 'darwin' and os.uname().machine == 'arm64':
        # checkra1n's macOS build is Intel-only.
        rosetta = run(['arch', '-x86_64', '/usr/bin/true'], capture_output=True)
        require(rosetta.returncode == 0, 'checkra1n needs Rosetta on this Mac. Install it with: '
                'softwareupdate --install-rosetta --agree-to-license')
    if sys.platform.startswith('linux') and os.geteuid() != 0:
        require(shutil.which('sudo') is not None, 'sudo is required to give checkra1n USB access.')
        command.insert(0, shutil.which('sudo'))
    return command


def wait_for_ssh(udid=None, timeout=300, sleep=time.sleep, now=time.monotonic):
    """Wait until iOS is back and checkra1n's SSH server answers over USB."""
    print('Waiting for iOS to start...', flush=True)
    deadline = now() + timeout
    last = None
    while now() < deadline:
        try:
            usbmux.connect(SSH_PORT, udid).close()
            return
        except usbmux.UsbmuxError as error:
            last = error
        sleep(3)
    raise ValueError(f"checkra1n's SSH server did not come up: {last}. Unlock the device; if it stays in iOS "
                     'without the checkra1n app, run checkra1n again.')


def run(executable, ask=input):
    app, helper = payload()
    work = ROOT / '.work'
    work.mkdir(exist_ok=True, mode=0o700)
    # checkra1n's command line keeps waiting for the next DFU device after it boots this one.
    boot_run.run(checkra1n_command(executable), work / 'checkra1n.log', done=CHECKRA1N_DONE)
    wait_for_ssh()
    # A short folder: the SSH control socket's path must stay under 104 bytes.
    with tempfile.TemporaryDirectory(prefix='resize-apfs-', dir='/tmp') as work:
        session = Session(work)
        session.open()
        try:
            remove_leftovers(session)
            install(session, app, helper)
            process = start_helper(session)
            while True:
                ask('Resize APFS is on the Home Screen. Press Enter here when you are done to remove it. ')
                if not busy(session):
                    break
                print('A resize is still running. Wait until the app shows it has finished.')
            finish(session, process)
            print('Removed.')
        finally:
            session.close()
