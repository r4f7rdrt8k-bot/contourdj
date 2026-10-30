# Contour 0.1.1 performance verification

Measured on this Mac on 25 October 2026 (Cairo). This is a measured optimization of the existing app, not a claim of zero latency on every device or workload.

## Complete app

Three release-mode runs per version used the same two synthesized demos, playback/processing, Hotcue/loop/MIDI actions and WAV recording. Every before/after run passed the existing smoke checks.

| Median measurement | Before | After |
| --- | ---: | ---: |
| Process CPU time (user + system) | 8.48 s | 2.56 s |
| Elapsed time, including deliberate playback waits | 8.29 s | 4.98 s |
| Peak resident memory | 253,411,328 bytes | 246,611,968 bytes |

That is **69.8% less process CPU time** in this bounded workflow. Elapsed time includes fixed waits, and background load/temperature/caches affect timings. These values do not measure USB/controller-to-speaker latency. Raw trials: [before](app-before.json), [after](app-after.json), [comparison](app-comparison.json).

## What changed

- Playback clocks and the master meter notify only their small views. Unchanged paused positions no longer notify anything. Mixer controls no longer invalidate the whole workspace.
- Static waveform geometry is cached per size/track revision and rendered separately from the moving playhead. Resizing, loading a new track, cues and appearance remain supported.
- One adaptive snapshot timer runs at 30 Hz while active and 4 Hz while idle. Audio rendering remains running and independent of this UI clock.
- Library filtering/sorting and visible-order MIDI indices are cached until tracks, search, section or sort order change. Persistence snapshots coalesce, encode and write on a serial background queue, with a synchronous final flush at quit.
- PCM installation/reclamation moved off the main actor; decoding and demo synthesis perform less repeated work. Jog nudges use deadlines instead of one cancellable Task per event.
- MIDI uses indexed lookup, one fair FIFO drain worker, sampled diagnostics, timestamp-correct heartbeat handling and coalesced mapping writes. Control action order, note/touch edges and relative movement remain intact.
- The C++ core caches coefficients and avoids repeated per-sample calculations. The paused shortcut preserves effect/state tails; long audio/transport comparison and sanitizer checks corroborate behavior.

## Isolated results

| Workload | Before | After | Evidence |
| --- | ---: | ---: | --- |
| 10,000 unchanged model ticks: parent/deck notifications | 30,000 | 0 | [before](model-before.json), [after](model-after.json) |
| 100 repeated sorted queries over 5,000 tracks | 651.15 ms | 7.87 ms | same model evidence |
| Main-queue heartbeat gap during 8-minute load | 34.39 ms | 6.19 ms | [audio wrapper](audio-wrapper.md) |
| Demo preparation | 126.11 ms | 71.28 ms | same wrapper evidence |
| Mixed 180,000-message MIDI dispatch | 13.615 s | 0.0417 s | [MIDI report](midi-results.md) |
| Typical active C++ rendering | baseline | 17–33% lower median cost | [core audit](core-comparison.md) |

These microbenchmarks isolate their named subsystem. They are not all-app speedup ratios. Playhead positions still update through the dedicated clocks; removing parent notifications does not stop animation. Model tests verify that the final positions and library results remain identical. Some worst-case core outliers grew; the core audit reports those separately from medians.

## Regression verification

- All 14 core DSP checks passed normally and under ASan/UBSan; instrumented C++ render allocations/frees remained zero. Long old/new comparison covered 3,258,928 values with maximum difference 5.82e-11.
- Both demo variants retain their audio within maximum sample difference 2.98e-8.
- The original 18 MIDI checks and added FIFO/timestamp/flood checks passed; 150,000 queued actions retained exact order and terminal control values.
- Model checks verify search/section/sort/metadata cache invalidation, MIDI browsing in visible order, independent playhead/mixer updates and latest-state persistence on shutdown.
- The optimized packaged app passed actual playback, cues, looping, WAV recording and all seven synthetic codec imports. [Final smoke evidence](../app-smoke-test.json).
- Own-window light/dark/compact renders were inspected after the waveform changes. Native vibrancy/toolbar capture limitations from [validation](../validation.md) still apply.

Reproduce core and MIDI checks with `scripts/test-core.sh` and `scripts/test-midi.sh`; model checks with `scripts/test-model.sh`. Subsystem reports include their exact benchmark commands, preserved baseline sources and raw results.

## Remaining practical limits

Physical USB MIDI, output-device buffering and speaker latency were not measured. The app still uses the existing pitch-changing rate control, in-memory track bounds, prototype jog behavior and fixed recording ring. Slow storage can delay synchronous recorder open/finalization. MIDI drain passes are bounded, while backlog memory may grow if the main actor is blocked for a prolonged period; the implementation preserves ordered edges rather than discarding them. Tests do not certify every UI state or guarantee dropout-free use on all systems.
