#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/midi-module-cache" Sources/Contour/MIDIController.swift Tests/MIDIChecks.swift -o .build/midi-checks
.build/midi-checks
