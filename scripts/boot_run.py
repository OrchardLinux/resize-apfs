"""Run palera1n or checkra1n with its output in a log, as Orchard's launcher does.

The terminal shows what to do (DFU, the cable hint) and the outcome; the tool's own
banner and steps go to the log, which is shown only when the boot fails.
"""
import os
import signal
import subprocess

# Waiting for the user to enter DFU mode is part of the run.
TIMEOUT = 600


def run(argv, log, timeout=TIMEOUT, popen=subprocess.Popen):
    """Run `argv` with its output in `log`; raise ValueError with the log's end on failure.

    palera1n starts checkra1n and only waits for it. Stopping palera1n alone would leave
    checkra1n exploiting the next DFU device it sees, so the whole process group stops.
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
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop(process)
            raise ValueError(f'No device booted within {timeout // 60} minutes. Log: {log}')
        except BaseException:
            stop(process)
            raise
    if returncode:
        raise ValueError(f'{os.path.basename(argv[0])} did not boot the device.\n' + tail(log) + f'\nLog: {log}')


def stop(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Started through sudo: the group belongs to root.
        subprocess.run(['sudo', '-n', 'kill', '-KILL', f'-{process.pid}'], capture_output=True, timeout=10)
    process.wait()


def tail(log, lines=5):
    try:
        text = open(log, 'rb').read().decode(errors='replace')
    except OSError:
        return ''
    return '\n'.join('  ' + line for line in text.strip().splitlines()[-lines:])
