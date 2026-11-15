#!/bin/sh
# Runs the test suite. With full Xcode, plain `swift test` works. With only the
# Command Line Tools, Swift Testing lives in a framework folder SwiftPM does not
# search by default, so point it there.
set -e
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if xcode-select -p 2>/dev/null | grep -q CommandLineTools && [ -d "$CLT/Frameworks/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
