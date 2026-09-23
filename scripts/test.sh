#!/usr/bin/env bash
# Run the test suite.
#
# swift-testing ships inside the Command Line Tools, but SwiftPM does not wire it up
# there. On a CLT-only machine `swift test` needs three separate fixes:
#
#   1. -F           the framework is not on the default search path
#                   ("no such module 'Testing'")
#   2. -rpath       and not on the runtime path either
#                   (dlopen: Library not loaded: @rpath/Testing.framework/...)
#   3. -disable-cross-import-overlays
#                   `import Testing` alongside `import Foundation` pulls in the
#                   _Testing_Foundation cross-import overlay, and Apple ships that
#                   framework's binary without its Modules/ directory — there is no
#                   .swiftinterface to compile against, so the import cannot resolve.
#                   Disabling overlay lookup sidesteps it; nothing in our tests needs
#                   the overlay's API.
#
# A full Xcode install needs none of this, so we detect rather than hardcode.
set -euo pipefail

cd "$(dirname "$0")/.."

frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
flags=()
if [ -d "$frameworks/Testing.framework" ]; then
    flags=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    )
fi

exec swift test "${flags[@]}" "$@"
