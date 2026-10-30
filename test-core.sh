#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$task_root/.build/core-validation"
mkdir -p "$task_build" "$task_root/docs"
if [[ "${1:-}" == "--benchmark" ]]; then
  task_label="${2:-after}"
  if [[ "$task_label" != "before" && "$task_label" != "after" ]]; then
    echo "Benchmark label must be before or after" >&2; exit 2
  fi
  task_source="$task_root/Sources/CDJCore/CDJCore.cpp"
  if [[ "$task_label" == "before" ]]; then task_source="$task_root/docs/performance/baseline-source/CDJCore.cpp"; fi
  mkdir -p "$task_root/docs/performance"
  /usr/bin/clang++ -std=c++17 -O3 -DNDEBUG -Wall -Wextra -pthread \
    -I "$task_root/Sources/CDJCore/include" "$task_source" \
    "$task_root/Tests/Standalone/CoreBenchmark.cpp" -o "$task_build/core-benchmark-$task_label"
  "$task_build/core-benchmark-$task_label" "$task_root/docs/performance/core-$task_label.json" "$task_root/docs/performance/core-$task_label.f32"
  exit
fi
if [[ "${1:-}" == "--equivalence" ]]; then
  mkdir -p "$task_root/docs/performance"
  for task_label in before after; do
    task_source="$task_root/Sources/CDJCore/CDJCore.cpp"
    if [[ "$task_label" == "before" ]]; then task_source="$task_root/docs/performance/baseline-source/CDJCore.cpp"; fi
    /usr/bin/clang++ -std=c++17 -O3 -DNDEBUG -Wall -Wextra -pthread \
      -I "$task_root/Sources/CDJCore/include" "$task_source" \
      "$task_root/Tests/Standalone/CoreEquivalence.cpp" -o "$task_build/core-equivalence-$task_label"
    "$task_build/core-equivalence-$task_label" "$task_root/docs/performance/edge-$task_label.f32"
  done
  python3 - "$task_root" <<'PY'
import array,json,math,pathlib,sys
r=pathlib.Path(sys.argv[1])/'docs/performance';a=array.array('f');b=array.array('f')
a.frombytes((r/'edge-before.f32').read_bytes());b.frombytes((r/'edge-after.f32').read_bytes());assert len(a)==len(b)
maximum=0.0;squared=0.0;different=0;nonfinite=0
for x,y in zip(a,b):
    delta=abs(float(x)-float(y));maximum=max(maximum,delta);squared+=delta*delta;different+=delta!=0;nonfinite+=not math.isfinite(x) or not math.isfinite(y)
d={'float_values':len(a),'max_absolute_difference':maximum,'rms_difference':math.sqrt(squared/max(1,len(a))),'differing_values':different,'nonfinite_values':nonfinite,'tolerance':1e-6,'passed':maximum<=1e-6 and not nonfinite,'scope':'2400blocks with0/1/7/63/128/257/512/1024/4096frames; control ramps, allFX, pause/resume/tails, filter/EQ, source reload, reverse/loops, pattern toggles, recording; stereo samples plus block-end transport state.'}
(r/'equivalence-edge-cases.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps(d,indent=2));sys.exit(0 if d['passed'] else 1)
PY
  exit
fi
task_flags=(-std=c++17 -O2 -Wall -Wextra -pthread)
task_binary="$task_build/dsp-tests"
task_report="$task_root/docs/core-test-results.json"
if [[ "${SANITIZE:-0}" == "1" ]]; then
  task_flags+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
  task_binary="$task_build/dsp-tests-asan"
  task_report="$task_root/docs/core-test-results-asan.json"
fi
/usr/bin/clang++ "${task_flags[@]}" -I "$task_root/Sources/CDJCore/include" \
  "$task_root/Sources/CDJCore/CDJCore.cpp" "$task_root/Tests/Standalone/DSPTests.cpp" \
  -o "$task_binary"
"$task_binary" "$task_report" "$task_build/offline-mix.wav"
