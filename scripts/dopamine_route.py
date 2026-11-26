"""Resize APFS without DFU: one app, installed with the user's Apple ID.

The app is the pinned Dopamine (A8 to A13 on iOS 15.0-18.7.1 and 26.0-26.0.1, A14 and later on
iOS 15.0-17.3.1) with Resize APFS in it (embed.py). Opened on the device, it shows only Resize
APFS, obtains storage access through Dopamine by itself, installs its storage helper as a
launch daemon and talks to it as root (App/StorageAccess.swift). Nothing is copied to the
device from here afterwards: no SSH, no password, nothing to remove at the end.

Before installing, the user confirms Developer Mode is on. The launcher then signs the app
with the user's Apple ID and installs it, after one confirmation (sideload.py); where xtool has
no release, it leaves the prepared app for the user to sign and install themselves.
"""
import pathlib

import embed
import sideload
import usbmux
from image_format import require

ROOT = pathlib.Path(__file__).resolve().parents[1]

DEVELOPER_MODE = ('Turn on Developer Mode on the device: Settings > Privacy & Security > Developer Mode, '
                  'then restart it and confirm "Turn On".\n'
                  'Press Enter when Developer Mode is on. ')
# Where xtool has no release: the user signs and installs it with a tool of their own.
SIGN = ('Sign Resize APFS with your Apple ID and install it on the device, with Xcode, Sideloadly, '
        'AltStore or another sideloading tool. The app:\n'
        '  {}\n'
        'A free Apple ID signs it for 7 days; sign it again when it stops opening.\n'
        'Press Enter when Resize APFS is on the device. ')
OPEN = ('Open Resize APFS on the device. It gets storage access by itself: the screen goes dark once; '
        'unlock the device when it comes back.')


def device(devices=usbmux.devices):
    """The UDID of the one iOS device connected over USB."""
    found = devices()
    require(found, 'No iOS device is connected over USB. Connect the device, unlock it and trust this computer.')
    require(len(found) == 1, 'More than one iOS device is connected. Connect only the device to resize.')
    return found[0][1]


def run(ipa, ask=input, signer=sideload, devices=usbmux.devices, work=None, payload=None):
    """Install the app on the connected device; the user confirms each step."""
    payload = sideload.PAYLOAD if payload is None else payload
    sideload.payload_key(payload)
    ask(DEVELOPER_MODE)
    if signer.available():
        signer.install(ipa, device(devices), ask)
    else:
        work = pathlib.Path(work or ROOT / '.work/sideload')
        work.mkdir(parents=True, exist_ok=True)
        ask(SIGN.format(embed.prepared_ipa(ipa, work, payload)))
    print(OPEN, flush=True)
