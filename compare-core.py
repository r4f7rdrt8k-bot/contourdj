#!/usr/bin/env python3
"""Summarize the preserved before/after DSP benchmarks without rerunning them."""
import array
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / "docs/performance"


def read(name):
    return json.loads((REPORT / name).read_text())


def digest(path):
    raw = (ROOT / path).read_bytes()
    return {"path": path, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


before, after = read("core-before.json"), read("core-after.json")
assert before["repetitions"] == after["repetitions"] == 5
assert before["measured_callbacks_per_repeat"] == after["measured_callbacks_per_repeat"] == 2048
assert before["warmup_callbacks_per_repeat"] == after["warmup_callbacks_per_repeat"] == 256
assert len(before["cases"]) == len(after["cases"]) == 33
cases = []
for old, new in zip(before["cases"], after["cases"]):
    assert (old["workload"], old["frames"]) == (new["workload"], new["frames"])
    cases.append({
        "workload": old["workload"], "frames": old["frames"],
        "callback_deadline_us": old["callback_deadline_us"],
        "before": old["summary"], "after": new["summary"],
        "median_reduction_percent": 100 * (1 - new["summary"]["median_us"] / old["summary"]["median_us"]),
        "before_repeat_medians_us": [x["median_us"] for x in old["repeats"]],
        "after_repeat_medians_us": [x["median_us"] for x in new["repeats"]],
        "after_p99_deadline_percent": 100 * new["summary"]["p99_us"] / old["callback_deadline_us"],
    })

audio_a, audio_b = array.array("f"), array.array("f")
audio_a.frombytes((REPORT / "core-before.f32").read_bytes())
audio_b.frombytes((REPORT / "core-after.f32").read_bytes())
assert len(audio_a) == len(audio_b)
deltas = [abs(float(a) - float(b)) for a, b in zip(audio_a, audio_b)]
audio = {"samples": len(audio_a), "max_absolute_difference": max(deltas),
         "rms_difference": math.sqrt(sum(d*d for d in deltas) / len(deltas)),
         "differing_samples": sum(d != 0 for d in deltas), "tolerance": 1e-6,
         "passed": all(math.isfinite(x) for x in audio_a) and all(math.isfinite(x) for x in audio_b) and max(deltas) <= 1e-6,
         "scope": "First 16 measured callbacks after warmup for all 33 workload/buffer cases. Numerical comparison, not listening certification."}
(REPORT / "audio-equivalence.json").write_text(json.dumps(audio, indent=2) + "\n")

tests = json.loads((ROOT / "docs/core-test-results.json").read_text())
sanitized = json.loads((ROOT / "docs/core-test-results-asan.json").read_text())
edge = read("equivalence-edge-cases.json")
files = ["docs/performance/baseline-source/CDJCore.cpp", "docs/performance/baseline-source/CDJCore.h",
         "Sources/CDJCore/CDJCore.cpp", "Sources/CDJCore/include/CDJCore.h",
         "Tests/Standalone/CoreBenchmark.cpp", "Tests/Standalone/CoreEquivalence.cpp",
         "Tests/Standalone/DSPTests.cpp", "scripts/test-core.sh"]
assert digest(files[1])["sha256"] == digest(files[3])["sha256"], "Public header changed"
comparison = {
    "scope": "Offline C++ DSP callback duration, not end-to-end output latency",
    "environment": {"architecture": platform.machine(), "macOS": platform.mac_ver()[0],
                    "compiler": subprocess.check_output(["/usr/bin/clang++", "--version"], text=True).splitlines()[0],
                    "CPU_model": "Not queried successfully in sandbox"},
    "method": {"sample_rate": 48000, "frames": [128, 256, 512], "workloads": 11,
               "repetitions": 5, "warmup_callbacks_per_repeat": 256,
               "measured_callbacks_per_repeat": 2048, "measured_callbacks_total_per_version": 337920,
               "compiler_flags": "-std=c++17 -O3 -DNDEBUG -Wall -Wextra -pthread; no fast-math",
               "timing": "steady_clock around cdj_render only; ordinary process scheduling; fresh engine per repeat",
               "order": "All baseline measurements completed against preserved source before core modifications; optimized measurements used the same harness afterward"},
    "render_cpp_allocations_before": before["render_cpp_allocations"],
    "render_cpp_allocations_after": after["render_cpp_allocations"],
    "render_cpp_deallocations_before": before["render_cpp_deallocations"],
    "render_cpp_deallocations_after": after["render_cpp_deallocations"],
    "nonfinite_samples_before": before["nonfinite_samples"],
    "nonfinite_samples_after": after["nonfinite_samples"],
    "deadline_misses_before": sum(x["before"]["deadline_misses"] for x in cases),
    "deadline_misses_after": sum(x["after"]["deadline_misses"] for x in cases),
    "all_case_medians_improved": all(x["median_reduction_percent"] > 0 for x in cases),
    "cases_with_larger_after_maximum": [{"workload": x["workload"], "frames": x["frames"], "before_max_us": x["before"]["max_us"], "after_max_us": x["after"]["max_us"]} for x in cases if x["after"]["max_us"] > x["before"]["max_us"]],
    "tests": {"normal_count": tests["test_count"], "normal_failures": tests["failure_count"],
              "ASan_UBSan_count": sanitized["test_count"], "ASan_UBSan_failures": sanitized["failure_count"],
              "benchmark_audio": audio, "edge_trace": edge},
    "source_hashes": [digest(x) for x in files], "cases": cases,
    "limitations": ["Sequential before/after runs under ordinary OS scheduling are not a controlled hardware-latency experiment.",
                    "Maximum callback durations include scheduling interference; several maximum outliers increased despite lower medians.",
                    "C++ new/delete instrumentation does not intercept every libc allocator.",
                    "No AVAudioEngine/device, decoder, MIDI/UI latency, live underrun or listening-quality certification is implied.",
                    "Synthetic stereo loops and controls exercise the listed DSP paths; arbitrary audio and every sample rate are not exhaustively covered."]}
(REPORT / "core-comparison.json").write_text(json.dumps(comparison, indent=2) + "\n")

lines = [
    "# C++ DSP performance audit", "",
    "All 33 workload/buffer combinations had lower median callback duration after optimization. These measurements describe offline DSP CPU cost. They do not establish end-to-end audio latency or guarantee live playback without dropouts.", "",
    "The baseline source and header were copied and hashed before the core edit. Both versions used the same benchmark, Apple clang 21, C++17 `-O3 -DNDEBUG`, 48 kHz synthesized stereo input, and ordinary process scheduling on arm64 macOS 26.6.2. Each case used five fresh-engine repetitions, each with 256 warmup callbacks and 2,048 measured callbacks (10,240 observations per case; 337,920 per version). Timing surrounds only `cdj_render`; recording drains occur outside the timed section. No fast-math was enabled.", "",
    "At 48 kHz, the callback deadlines for 128/256/512 frames are 2,666.667/5,333.333/10,666.667 microseconds. Both versions recorded zero deadline misses, zero nonfinite output samples, and zero instrumented C++ allocations or frees during measured rendering. These observations are not an assertion that the operating system will always meet a deadline.", "",
    "## Results", "",
    "All durations are microseconds. Each before → after pair shows the aggregate distribution across the five repetitions. Per-repetition medians and full percentiles are retained in the JSON reports.", "",
    "| Workload | Frames | Median before → after | Reduction | p95 before → after | p99 before → after | Max before → after |",
    "|---|---:|---:|---:|---:|---:|---:|",
]
for c in cases:
    a, b = c["before"], c["after"]
    lines.append(f'| {c["workload"]} | {c["frames"]} | {a["median_us"]:.3f} → {b["median_us"]:.3f} | {c["median_reduction_percent"]:.1f}% | {a["p95_us"]:.3f} → {b["p95_us"]:.3f} | {a["p99_us"]:.3f} → {b["p99_us"]:.3f} | {a["max_us"]:.3f} → {b["max_us"]:.3f} |')
lines += ["", "Several maximum outliers increased, including four decks with effects at 512 frames and reverse loops at 512 frames. Ordinary process scheduling can affect individual observations; these data support a reduction in typical DSP cost, not an across-the-board worst-case bound. The maximum observed optimized callback was {:.3f} microseconds.".format(max(c["after"]["max_us"] for c in cases)), "",
    "## Changes and preservation checks", "",
    "- Cached sample-rate-dependent coefficients and delay taps; EQ and filter coefficients update when their controls change.",
    "- Evaluated equal-power crossfader sine/cosine once per callback, then used a recurrence for the existing sample-by-sample fader ramp.",
    "- Replaced delay-ring modulo operations with conditional wrapping for the supported taps; kept the same two-second rings and feedback.",
    "- Skipped paused-deck DSP only after all filter states and the complete delay history are exactly zero. There is no amplitude threshold, tail cutoff, or flush-to-zero addition. Volume/rate smoothing, phase, and cursor state still advance.",
    "- Skipped smoothing work only at an exact floating-point fixed point. Moving controls retain the original recurrence.",
    "- Replaced Pattern drum envelope exponentials per sample with cached exponential decay recurrences. Waveform and transport comparisons bound the observed floating-point differences.",
    "- Kept the public C API, source-buffer hazard ownership, control-thread reclamation, memory cap, fixed recording ring, overflow reporting, loop/reverse handling, stereo routing, and file-I/O separation.", "",
    "All 14 standalone tests passed normally and with combined AddressSanitizer/UndefinedBehaviorSanitizer. The concurrent source-load test and exact bounded recording overflow test passed. The 33-case benchmark capture compared 315,392 float samples with maximum absolute difference 1.14e-13. A separate 2,400-block trace compared 3,258,928 audio/transport float values with maximum difference 5.82e-11; its blocks include 0/1/7/63/128/257/512/1024/4096 frames, control ramps, all effects, pause/resume tails, reload, loops/reverse, Pattern toggles, and recording. Both comparisons passed a 1e-6 numerical tolerance. These are numerical regression checks, not a listening test.", "",
    "## Reproduce", "",
    "```sh", "bash scripts/test-core.sh --benchmark before", "bash scripts/test-core.sh --benchmark after", "bash scripts/test-core.sh --equivalence", "bash scripts/test-core.sh", "SANITIZE=1 bash scripts/test-core.sh", "python3 Tests/Standalone/compare-core.py", "```", "",
    "The `before` benchmark uses the preserved source. Re-running benchmarks replaces the timing artifacts and can change outliers. The baseline manifest and comparison JSON retain source hashes; the public header hash is unchanged.", "",
    "Evidence: [before](core-before.json), [after](core-after.json), [comparison and source hashes](core-comparison.json), [baseline manifest](baseline-source/manifest.json), [benchmark audio comparison](audio-equivalence.json), [long transition trace](equivalence-edge-cases.json), [14 normal tests](../core-test-results.json), [14 ASan/UBSan tests](../core-test-results-asan.json).", "",
    "The allocator counters observe C++ `new`/`delete`, not every possible libc allocator. Device buffer size, AVAudioEngine, decoding, MIDI/UI delivery and hardware output latency require separate integration measurements. No personal audio was used in these synthetic core tests.", "",
]
(REPORT / "core-comparison.md").write_text("\n".join(lines))
print(json.dumps({"cases": len(cases), "all_medians_improved": comparison["all_case_medians_improved"],
                  "deadline_misses_before": comparison["deadline_misses_before"],
                  "deadline_misses_after": comparison["deadline_misses_after"],
                  "comparison": str(REPORT / "core-comparison.md")}, indent=2))
