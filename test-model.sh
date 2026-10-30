#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift build -c release --product Contour --disable-sandbox --cache-path "$PWD/.build/cache"
mkdir -p .build/performance
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path .build/performance/model-module-cache -I .build/release/CDJCore.build Sources/Contour/AudioEngine.swift Sources/Contour/MIDIController.swift Sources/Contour/Models.swift Sources/Contour/PerformanceState.swift Tests/Performance/ModelChecks.swift .build/release/CDJCore.build/CDJCore.cpp.o -lc++ -o .build/performance/model-checks
CONTOUR_DATA_DIR="$PWD/.test-data-model-regression" .build/performance/model-checks
