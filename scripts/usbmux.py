"""A TCP connection to a port on a USB-connected iOS device, through usbmuxd.

usbmuxd is the system service Finder and iTunes use to talk to iOS over the cable: built into
macOS, the `usbmuxd` package on Linux. It is not a network interface, so macOS asks for no
permission. Protocol: 16-byte little-endian header (length, version 1, type 8 = plist, tag),
then an XML plist; after a successful Connect the socket carries the device port's bytes.

    usbmux.py list               the connected devices
    usbmux.py proxy PORT [UDID]  pipe stdin/stdout to PORT on the device (an ssh ProxyCommand)
"""
import os
import plistlib
import select
import socket
import struct
import sys

SOCKET = os.environ.get('USBMUXD_SOCKET_ADDRESS', '/var/run/usbmuxd')
PROGRAM = 'resize-apfs'


class UsbmuxError(Exception):
    pass


def _receive(sock, size):
    data = b''
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise UsbmuxError('usbmuxd closed the connection.')
        data += chunk
    return data


def request(sock, message, tag=1):
    body = plistlib.dumps({**message, 'ClientVersionString': PROGRAM, 'ProgName': PROGRAM})
    sock.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)
    length, version, kind, _ = struct.unpack('<IIII', _receive(sock, 16))
    if version != 1 or kind != 8 or not 16 <= length <= 1 << 20:
        raise UsbmuxError('usbmuxd sent an unexpected reply.')
    return plistlib.loads(_receive(sock, length - 16))


def connect_service():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET)
    except OSError:
        sock.close()
        hint = '' if sys.platform == 'darwin' else ' Install and start usbmuxd (e.g. `sudo apt install usbmuxd`).'
        raise UsbmuxError('Cannot reach usbmuxd, the service that talks to iOS over USB.' + hint)
    return sock


def devices():
    """The serial numbers (UDIDs) of the iOS devices connected over USB, running iOS."""
    sock = connect_service()
    try:
        reply = request(sock, {'MessageType': 'ListDevices'})
    finally:
        sock.close()
    found = []
    for entry in reply.get('DeviceList', []):
        props = entry.get('Properties', {})
        if props.get('ConnectionType', 'USB') == 'USB':
            found.append((entry['DeviceID'], props.get('SerialNumber', '')))
    return found


def connect(port, udid=None):
    """An open socket to `port` on the device (the only one connected, or the one with `udid`)."""
    found = devices()
    if udid:
        found = [d for d in found if d[1] == udid]
    if not found:
        raise UsbmuxError('No iOS device is connected over USB.')
    if len(found) > 1:
        raise UsbmuxError('More than one iOS device is connected. Connect only the device to resize.')
    sock = connect_service()
    reply = request(sock, {'MessageType': 'Connect', 'DeviceID': found[0][0],
                           'PortNumber': socket.htons(port)})
    if reply.get('Number') != 0:
        sock.close()
        raise UsbmuxError(f'The device refused a connection to port {port} (usbmuxd result {reply.get("Number")}).')
    return sock


def proxy(port, udid=None):
    sock = connect(port, udid)
    stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
    while True:
        readable, _, _ = select.select([sock, stdin], [], [])
        if sock in readable:
            data = sock.recv(65536)
            if not data:
                return
            os.write(stdout, data)
        if stdin in readable:
            data = os.read(stdin, 65536)
            if not data:
                sock.shutdown(socket.SHUT_WR)
                break
            sock.sendall(data)
    # Our side has finished; pass on what the device still sends.
    while True:
        data = sock.recv(65536)
        if not data:
            return
        os.write(stdout, data)


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['list']:
            for _, serial in devices():
                print(serial)
        elif sys.argv[1:2] == ['proxy'] and len(sys.argv) in (3, 4):
            proxy(int(sys.argv[2]), sys.argv[3] if len(sys.argv) == 4 else None)
        else:
            sys.exit(__doc__)
    except (UsbmuxError, OSError) as error:
        sys.exit(f'usbmux: {error}')
