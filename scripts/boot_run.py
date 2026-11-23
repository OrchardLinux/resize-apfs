"""Run palera1n or checkra1n with its output in a log, as Orchard's launcher does.

The terminal shows what to do (DFU, the cable hint) and the outcome; the tool's own
banner and steps go to the log, which is shown only when the boot fails.
"""
import os
import signal
import subprocess
import time

# Waiting for the user to enter DFU mode is part of the run.
TIMEOUT = 600
# How often `booted` is asked while the tool runs.
POLL = 1
# How long a stopped tool gets to exit after SIGTERM before its group is killed.
STOP_GRACE = 5


def run(argv, log, timeout=TIMEOUT, popen=subprocess.Popen, booted=None):
    """Run `argv` with its output in `log`; raise ValueError with the log's end on failure.

    palera1n starts checkra1n and only waits for it. Stopping palera1n alone would leave
    checkra1n exploiting the next DFU device it sees, so the whole process group stops.

    `booted`: for a tool that does not exit after booting the device (checkra1n's command
    line waits for the next DFU device), a check of the booted device itself. The run ends
    at whichever comes first: the tool exits (non-zero: failure, with its log) or `booted()`
    is true (success: the tool's process group is stopped). Returns 'exited' or 'booted'.
    """
    if os.path.basename(argv[0]) == 'sudo':
        # Ask for the password here: the tool itself runs detached from the terminal.
        if subprocess.run([argv[0], '-v']).returncode:
            raise ValueError('sudo is needed to give the tool USB access.')
        argv = [argv[0], '-n', *argv[1:]]
    print('Put the device in DFU mode.\n'
          'If the Apple logo stays for more than a few seconds, reconnect the cable at the device once.',
          flush=True)
    with open(log, 'wb') as stream:
        process = popen(argv, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                        start_new_session=True)
        try:
            if booted is None:
                returncode = process.wait(timeout=timeout)
            else:
                returncode = wait_for_boot(process, booted, timeout)
                if returncode is None:
                    stop(process, grace=STOP_GRACE)
                    return 'booted'
        except subprocess.TimeoutExpired:
            stop(process)
            raise ValueError(f'No device booted within {timeout // 60} minutes. Log: {log}')
        except BaseException:
            stop(process)
            raise
    if returncode:
        raise ValueError(f'{os.path.basename(argv[0])} did not boot the device.\n' + tail(log) + f'\nLog: {log}')
    return 'exited'


def wait_for_boot(process, booted, timeout, now=time.monotonic):
    """The tool's exit status once it exits, or None once `booted()` is true, whichever
    is first; TimeoutExpired after `timeout` seconds without either."""
    deadline = now() + timeout
    while True:
        try:
            return process.wait(timeout=max(0, min(POLL, deadline - now())))
        except subprocess.TimeoutExpired:
            pass
        if booted():
            # The device is up: that is the outcome, whatever the tool does next.
            return None
        if now() >= deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)


def stop(process, grace=0):
    """Stop the tool's process group: SIGTERM and up to `grace` seconds to exit, then SIGKILL."""
    if grace:
        _signal_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
    _signal_group(process, signal.SIGKILL)
    process.wait()


def _signal_group(process, number):
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Started through sudo: the group belongs to root.
        subprocess.run(['sudo', '-n', 'kill', f'-{signal.Signals(number).name[3:]}', f'-{process.pid}'],
                       capture_output=True, timeout=10)


def tail(log, lines=5):
    try:
        text = open(log, 'rb').read().decode(errors='replace')
    except OSError:
        return ''
    return '\n'.join('  ' + line for line in text.strip().splitlines()[-lines:])
