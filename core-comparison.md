# C++ DSP performance audit

All 33 workload/buffer combinations had lower median callback duration after optimization. These measurements describe offline DSP CPU cost. They do not establish end-to-end audio latency or guarantee live playback without dropouts.

The baseline source and header were copied and hashed before the core edit. Both versions used the same benchmark, Apple clang 21, C++17 `-O3 -DNDEBUG`, 48 kHz synthesized stereo input, and ordinary process scheduling on arm64 macOS 26.6.2. Each case used five fresh-engine repetitions, each with 256 warmup callbacks and 2,048 measured callbacks (10,240 observations per case; 337,920 per version). Timing surrounds only `cdj_render`; recording drains occur outside the timed section. No fast-math was enabled.

At 48 kHz, the callback deadlines for 128/256/512 frames are 2,666.667/5,333.333/10,666.667 microseconds. Both versions recorded zero deadline misses, zero nonfinite output samples, and zero instrumented C++ allocations or frees during measured rendering. These observations are not an assertion that the operating system will always meet a deadline.

## Results

All durations are microseconds. Each before → after pair shows the aggregate distribution across the five repetitions. Per-repetition medians and full percentiles are retained in the JSON reports.

| Workload | Frames | Median before → after | Reduction | p95 before → after | p99 before → after | Max before → after |
|---|---:|---:|---:|---:|---:|---:|
| idle_empty | 128 | 0.500 → 0.084 | 83.2% | 0.542 → 0.125 | 0.584 → 0.125 | 23.917 → 0.458 |
| idle_empty | 256 | 0.750 → 0.084 | 88.8% | 0.792 → 0.125 | 0.875 → 0.125 | 14.791 → 0.500 |
| idle_empty | 512 | 1.084 → 0.125 | 88.5% | 1.209 → 0.125 | 1.250 → 0.167 | 11.125 → 1.250 |
| paused_four_decks | 128 | 3.875 → 1.208 | 68.8% | 4.458 → 1.375 | 4.708 → 1.375 | 16.959 → 9.334 |
| paused_four_decks | 256 | 7.125 → 2.041 | 71.4% | 7.250 → 2.292 | 7.917 → 2.292 | 17.083 → 11.375 |
| paused_four_decks | 512 | 14.125 → 3.541 | 74.9% | 14.291 → 3.792 | 15.208 → 3.917 | 29.292 → 12.458 |
| two_decks_dry | 128 | 2.458 → 1.959 | 20.3% | 2.542 → 2.084 | 2.625 → 2.125 | 14.375 → 11.167 |
| two_decks_dry | 256 | 4.958 → 4.041 | 18.5% | 5.042 → 4.125 | 5.125 → 4.208 | 14.666 → 12.458 |
| two_decks_dry | 512 | 9.625 → 7.958 | 17.3% | 9.792 → 8.166 | 9.958 → 9.667 | 24.708 → 21.875 |
| four_decks_dry | 128 | 4.750 → 3.875 | 18.4% | 4.917 → 4.042 | 5.000 → 4.584 | 14.417 → 12.583 |
| four_decks_dry | 256 | 9.333 → 7.708 | 17.4% | 9.625 → 7.875 | 9.709 → 8.500 | 18.333 → 17.667 |
| four_decks_dry | 512 | 18.542 → 15.375 | 17.1% | 19.250 → 15.625 | 30.625 → 15.750 | 74.291 → 24.750 |
| four_decks_fx | 128 | 6.250 → 4.791 | 23.3% | 6.417 → 4.875 | 17.000 → 4.958 | 20.500 → 17.666 |
| four_decks_fx | 256 | 12.333 → 9.375 | 24.0% | 12.500 → 9.583 | 12.625 → 9.750 | 25.708 → 22.625 |
| four_decks_fx | 512 | 24.542 → 18.625 | 24.1% | 24.875 → 19.042 | 29.042 → 22.208 | 36.833 → 70.958 |
| pattern_only | 128 | 1.958 → 0.917 | 53.2% | 2.000 → 0.959 | 2.041 → 1.000 | 9.709 → 6.709 |
| pattern_only | 256 | 3.875 → 1.792 | 53.8% | 3.917 → 1.834 | 3.959 → 1.875 | 13.083 → 10.750 |
| pattern_only | 512 | 7.667 → 3.583 | 53.3% | 7.750 → 3.625 | 7.833 → 3.667 | 22.166 → 10.834 |
| four_decks_fx_pattern | 128 | 8.042 → 5.417 | 32.6% | 8.167 → 5.542 | 8.250 → 5.625 | 17.958 → 14.667 |
| four_decks_fx_pattern | 256 | 15.916 → 10.791 | 32.2% | 16.125 → 11.000 | 16.250 → 11.167 | 25.875 → 24.042 |
| four_decks_fx_pattern | 512 | 31.708 → 21.375 | 32.6% | 32.083 → 21.625 | 36.792 → 24.833 | 52.583 → 39.417 |
| paused_fx_tails | 128 | 5.292 → 3.625 | 31.5% | 5.375 → 3.750 | 5.459 → 3.834 | 13.458 → 13.667 |
| paused_fx_tails | 256 | 10.500 → 7.167 | 31.7% | 10.625 → 7.417 | 10.750 → 7.541 | 22.458 → 24.875 |
| paused_fx_tails | 512 | 20.834 → 14.500 | 30.4% | 21.083 → 14.750 | 23.542 → 16.209 | 42.083 → 51.750 |
| smoothed_controls | 128 | 6.459 → 4.792 | 25.8% | 6.875 → 4.916 | 6.959 → 4.959 | 23.209 → 19.833 |
| smoothed_controls | 256 | 12.833 → 9.542 | 25.6% | 13.625 → 9.667 | 14.709 → 9.750 | 43.584 → 20.583 |
| smoothed_controls | 512 | 25.708 → 18.958 | 26.3% | 27.000 → 19.167 | 30.208 → 21.834 | 58.834 → 49.875 |
| reverse_loops | 128 | 6.208 → 4.709 | 24.1% | 6.292 → 4.833 | 6.375 → 4.875 | 16.916 → 14.166 |
| reverse_loops | 256 | 12.250 → 9.333 | 23.8% | 12.417 → 9.541 | 12.541 → 9.625 | 26.042 → 22.625 |
| reverse_loops | 512 | 24.458 → 18.500 | 24.4% | 24.667 → 18.917 | 28.459 → 19.166 | 36.417 → 95.250 |
| four_decks_recording | 128 | 8.083 → 5.459 | 32.5% | 8.208 → 5.584 | 8.291 → 5.667 | 17.584 → 18.541 |
| four_decks_recording | 256 | 16.000 → 10.834 | 32.3% | 16.208 → 11.042 | 16.458 → 11.208 | 28.208 → 23.500 |
| four_decks_recording | 512 | 31.792 → 21.500 | 32.4% | 32.166 → 21.834 | 36.458 → 26.167 | 50.667 → 52.875 |

Several maximum outliers increased, including four decks with effects at 512 frames and reverse loops at 512 frames. Ordinary process scheduling can affect individual observations; these data support a reduction in typical DSP cost, not an across-the-board worst-case bound. The maximum observed optimized callback was 95.250 microseconds.

## Changes and preservation checks

- Cached sample-rate-dependent coefficients and delay taps; EQ and filter coefficients update when their controls change.
- Evaluated equal-power crossfader sine/cosine once per callback, then used a recurrence for the existing sample-by-sample fader ramp.
- Replaced delay-ring modulo operations with conditional wrapping for the supported taps; kept the same two-second rings and feedback.
- Skipped paused-deck DSP only after all filter states and the complete delay history are exactly zero. There is no amplitude threshold, tail cutoff, or flush-to-zero addition. Volume/rate smoothing, phase, and cursor state still advance.
- Skipped smoothing work only at an exact floating-point fixed point. Moving controls retain the original recurrence.
- Replaced Pattern drum envelope exponentials per sample with cached exponential decay recurrences. Waveform and transport comparisons bound the observed floating-point differences.
- Kept the public C API, source-buffer hazard ownership, control-thread reclamation, memory cap, fixed recording ring, overflow reporting, loop/reverse handling, stereo routing, and file-I/O separation.

All 14 standalone tests passed normally and with combined AddressSanitizer/UndefinedBehaviorSanitizer. The concurrent source-load test and exact bounded recording overflow test passed. The 33-case benchmark capture compared 315,392 float samples with maximum absolute difference 1.14e-13. A separate 2,400-block trace compared 3,258,928 audio/transport float values with maximum difference 5.82e-11; its blocks include 0/1/7/63/128/257/512/1024/4096 frames, control ramps, all effects, pause/resume tails, reload, loops/reverse, Pattern toggles, and recording. Both comparisons passed a 1e-6 numerical tolerance. These are numerical regression checks, not a listening test.

## Reproduce

```sh
bash scripts/test-core.sh --benchmark before
bash scripts/test-core.sh --benchmark after
bash scripts/test-core.sh --equivalence
bash scripts/test-core.sh
SANITIZE=1 bash scripts/test-core.sh
python3 Tests/Standalone/compare-core.py
```

The `before` benchmark uses the preserved source. Re-running benchmarks replaces the timing artifacts and can change outliers. The baseline manifest and comparison JSON retain source hashes; the public header hash is unchanged.

Evidence: [before](core-before.json), [after](core-after.json), [comparison and source hashes](core-comparison.json), [baseline manifest](baseline-source/manifest.json), [benchmark audio comparison](audio-equivalence.json), [long transition trace](equivalence-edge-cases.json), [14 normal tests](../core-test-results.json), [14 ASan/UBSan tests](../core-test-results-asan.json).

The allocator counters observe C++ `new`/`delete`, not every possible libc allocator. Device buffer size, AVAudioEngine, decoding, MIDI/UI delivery and hardware output latency require separate integration measurements. No personal audio was used in these synthetic core tests.
