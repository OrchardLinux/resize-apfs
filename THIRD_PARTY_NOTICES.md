# Third-party notices

The APFS framework is Apple's proprietary software, loaded from the user's
installed operating system. It is not included in this release.

Hoolock Linux's `tools/resize.c` documents the APFS resizing technique used here.
Our helper calls the framework directly; it does not bundle Hoolock's executable.
https://github.com/HoolockLinux/docs

palera1n and jbinit informed the overlay integration and private API declarations.
palera1n is installed separately. Its boot payload is extracted and modified only
on the user's host, not included in our release ZIP. The licenses of the external
payload's individual components remain applicable.
https://github.com/palera1n/palera1n
https://github.com/palera1n/jbinit

Linux host image tools use `libdmg-hfsplus` under GPL-3.0:
https://github.com/planetbeing/libdmg-hfsplus

The bundled tools run as separate programs and are not linked into the iOS app
or helper. Complete corresponding source, the GPL license and local modification
notes are included in `third_party/libdmg-hfsplus/`; rebuild them with
`scripts/build-linux-tools.sh`. They dynamically use the host's libc and zlib.

The iOS 12-14 app bundles JetBrains Mono 2.304 (Regular, Medium, SemiBold, Bold)
under the SIL Open Font License 1.1. The license ships next to the fonts in
`App/Fonts/OFL.txt` and inside the app bundle.
Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)

The following MIT notice is retained for relevant upstream material:

Copyright (c) 2025 Hoolock Linux contributors
Copyright 2023 palera1n team
Copyright 2023 Nick Chan (jbinit / plooshinit)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The iOS 12-14 app (`out/device-ios12`) contains the Swift runtime and system
overlay libraries in `ResizeAPFS.app/Frameworks`, copied at build time from the
Xcode toolchain's back-deployment runtime (`usr/lib/swift-5.0/iphoneos`), because
iOS 12.0 and 12.1 have no Swift runtime. They are part of the Swift project,
licensed under the Apache License 2.0 with the Runtime Library Exception, which
permits redistributing them embedded in a compiled product. iOS 12.2 and later
use the system's copy instead.
https://www.swift.org/legal/license.html

Build tools such as Xcode and ldid are external dependencies and are not
included in the release.
