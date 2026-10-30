# Swift audio wrapper performance

The change keeps AVAudioEngine running after `start()` for responsive playback. It moves track preparation work away from the main actor, reduces timer/task churn, and preserves the existing public transport, meter, recorder, and load APIs. No C++ or output-routing behavior was changed by this wrapper work.

## Measured before and after

Standalone `swiftc -O` harness, three sequential runs per input, using one frozen release CDJCore object for both versions. The harness decodes and installs audio without starting output. A main-queue heartbeat requests service every 5 ms; the gap metric is the median of each run’s maximum observed gap. These measurements establish wrapper responsiveness under these fixtures, not audio-device latency or dropout-free performance.

| Case | Before median | After median | Change |
| --- | ---: | ---: | ---: |
| 40-second fixture load | 27.65 ms | 26.33 ms | 4.8% faster |
| 8-minute synthetic WAV load | 150.37 ms | 134.56 ms | 10.5% faster |
| Main heartbeat gap during 8-minute load | 34.39 ms | 6.19 ms | 82.0% smaller |
| 64-second demo generation + install | 126.11 ms | 71.28 ms | 43.5% faster |
| 10,000 synthetic jog calls, one burst | 2.629 ms | 0.197 ms | 92.5% less enqueue time |

Raw evidence: [load baseline](audio-wrapper-before.json), [optimized load](audio-wrapper-after.json), [jog baseline](audio-wrapper-jog-before.json), [optimized jog](audio-wrapper-jog-after.json), and [demo sample comparison](audio-wrapper-demo-comparison.json). The jog result is a single stress burst rather than a hardware test. The optimized burst recorded 10,000 events, one nudge restoration, and a return to 4 Hz polling.

Each generated demo still has 3,072,000 stereo frames. Both variants passed the 1e-6 sample-difference threshold: maximum absolute differences were 1.49e-8 and 2.98e-8; RMS differences were 1.27e-11 and 2.56e-11. This verifies the envelope optimization numerically; it does not evaluate speakers or a controller’s feel.

## Implementation

- `AudioCoreOwner` serializes PCM installation and retired-buffer reclamation on a dedicated maintenance queue. The C API still copies PCM into its own storage; that full copy and its allocation no longer occupy the main actor.
- Decode, waveform/BPM analysis, installation, and temporary Swift PCM destruction remain inside one background worker. Only the small `TrackAnalysis` returns to the main actor. Retaining the owner through queued work preserves the core’s lifetime; the source node also retains its owner until engine shutdown.
- The existing decode gate still bounds the entire decode/install pipeline to one job. Version checks reject superseded results. Parent cancellation is forwarded to the worker; file conversion checks cancellation between chunks, and demo synthesis checks every 8,192 frames.
- File conversion writes interleaved, sanitized samples into one preallocated buffer with an explicit initialized count. It avoids two array appends per stereo frame and retains the existing 10-minute input bound and C++ PCM budget.
- Demo synthesis precomputes the short repeating kick, snare, hat, bass, and lead envelopes, note frequencies, and pad interval. It retains the same oscillator/noise formula and duration.
- One timer runs on the main runloop in common modes. It invokes `poll()` directly using the known main-actor context, removing the former Task allocation at every tick. `onPoll: (@MainActor () -> Void)?` supplies the model’s sole UI snapshot clock.
- Polling is 30 Hz for playing decks, rhythm, recording, or recent jog activity; otherwise it is 4 Hz. Play, rhythm, recording, and jog commands immediately restore the active cadence. Natural playback completion and recorder errors are still sampled. Output rendering remains active for low-latency playback.
- Jog events update one deadline per deck. The next eligible poll restores the base rate after the 160 ms nudge window, with up to one active polling interval of extra delay. An explicit rate change or completed load clears the deadline. Paused scratch interaction keeps snapshots at 30 Hz for 200 ms after the last event.
- The published `masterPeak` API remains available and only assigns a changed value. Poll/jog counters are scalar increments; `performanceMetrics` constructs its dictionary only when a diagnostic caller requests it.

The render callback remains limited to buffer access and `cdj_render`. No Swift decoding, allocation, file operation, task dispatch, or timer work was added there.

## Reproduction and remaining limits

The preserved [baseline source](baseline-source/AudioEngine.swift) and appended [load harness](audio-wrapper-harness.swift) were compiled with `-O -parse-as-library`, the generated CDJCore module map, and the same frozen `CDJCore.cpp.o`. The [extra harness](audio-wrapper-extra-harness.swift) supplies jog stress and raw demo-array output. Compile the current wrapper with `-D OPTIMIZED`; omit that flag for the baseline. The harness expects a generated 8-minute stereo 48 kHz PCM16 WAV at `/private/tmp/contour-audio-wrapper-profile/eight-minute.wav`, with constant ±3276 channel samples, and the analysis fixture’s 40-second WAV at the absolute path recorded in its source. Both fixtures are synthetic.

The initial sandboxed CLI attempt could not instantiate the CoreAudio source component (`comp != nullptr`). Approved host execution supplied the required macOS audio/conversion services. Benchmarks did not start output or access personal tracks. The main responsiveness harness intentionally isolates decode/install operations from the native UI and uses a frozen DSP object; app-level startup, CPU, rendering and recording checks are reported separately by the main performance run.

Recording drain/write work already runs on its dedicated queue. The synchronous start and stop API still waits for file open/final flush and container closure; a slow disk can delay those calls. Shutdown intentionally finalizes the file before exit. A future asynchronous recording-finalization API would require matching model/UI state changes, and is not implied by this optimization.

Final core destruction still follows `engine.stop()` and can release the currently loaded PCM during shutdown. The new maintenance queue removes retired-track destruction from ordinary UI polling and loading; it does not claim instant process teardown.

The application still retains decoded track PCM and converts every imported file to stereo 48 kHz. Very large collections, live inputs, sustained multi-interface output, device reconnect, and real controller jog latency need separate workload tests. The 160 ms nudge is a transport prototype, not vinyl-style scratching or a sample-accurate gesture scheduler.
