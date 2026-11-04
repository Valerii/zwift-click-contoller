#!/usr/bin/env bash
# Runs the unit tests. With only the Xcode Command Line Tools installed, SwiftPM does not find
# the swift-testing macro plugin on its own, so point the compiler at it when it exists.
set -euo pipefail

PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGIN_DIR" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
else
    exec swift test "$@"
fi
