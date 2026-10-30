# MIDI performance verification

The same 360,000-message synthetic workload now routes all original action callbacks with equal counts and numeric checksums. The mixed 180,000-message case fell from 13.615s to 0.0417s in this isolated release-mode measurement. This is a MIDI parser/dispatch result, not an overall application speedup.

| Workload | MIDI messages | Before | After | Ratio | Observable notifications |
|---|---:|---:|---:|---:|---:|
| paired14 | 60,000 | 4.769s | 0.0382s | 124.8× | 89,800 → 2 |
| jog-notes | 120,000 | 9.140s | 0.0383s | 238.5× | 359,800 → 2 |
| mixed-running-status | 180,000 | 13.615s | 0.0417s | 326.6× | 449,800 → 2 |

Each comparison uses the same 30,000 cycles and a Combine `objectWillChange` subscriber. Analog updates use the actual custom LSB-first 14-bit pair; the mixed stream includes relative jog values and both press/release edges with running status. The benchmark callback checks numeric data without invoking the audio engine or rendering SwiftUI. These are single samples on macOS 26.6.2, arm64, Apple Swift 6.3.3 in Swift 5 language mode with `-O`. CPU model could not be read under the sandbox. The actual Swift 5.9 compiler was not available in this check.

## Changes

- Build a per-source/channel/status/control lookup once, invalidating it when mappings or source names change. Source-name normalization no longer scans every mapping on every event. Learn invalidation also takes effect inside the same packet.
- Keep structured diagnostics and publish sampled activity at 20 Hz. Formatting and rebuilding the 200-entry display history happen at publication time, while all control actions keep their original order. A delayed flush preserves the last event when input stops; Learn and connection status remain immediate.
- Replace one unbounded MainActor Task per callback list with a locked FIFO and a single scheduled drain worker. Every pass processes at most 32 chunks and 8192 bytes, then yields. Large packets split safely because running status survives chunk boundaries.
- Use CoreMIDI host timestamps, converted relative to callback receipt, for heartbeat freshness. Timestamp 0 falls back to receipt time. MainActor backlog no longer makes old heartbeats fresh. Disconnect releases held state and ignores that vanished source's queued input.
- Coalesce mapping preference edits for 100 ms and encode JSON on a utility task. `flushMappingChanges()` is available for deliberate application termination. The existing MIDI public API and firmware defaults remain intact.

No absolute updates, relative displacement, or note edges are coalesced or discarded by the normal FIFO. Coalescing was unnecessary after the lookup/logging changes and could alter action ordering. To retain every edge, **the pending backlog has no hard memory cap**; the bound applies to each drain pass. Under a prolonged blocked main thread, pending bytes can grow with input. The test recorded a peak of 304,710 pending bytes and drained back to 0.

## Sustained load and ordering

A separate continuous test ran each profile for at least 1.5 seconds, routing 16,500,000 MIDI messages total. Measured throughput ranged from 2.92 million to 4.33 million messages/second. Diagnostic notifications remained throttled. This loop intentionally runs synchronously for throughput measurement; it does not establish UI responsiveness.

The asynchronous test used a background producer through the same FIFO used by CoreMIDI: 180,000 messages, 150,000 action callbacks, exact action/value order verified, final analog value checked, final jog −1 and touch 0. It used 1 scheduled worker across 939 bounded passes. A concurrent 1 ms MainActor scheduling probe ran 23 times; its largest observed gap was 2.21 ms. This measures scheduling opportunity, not rendered frame rate or hardware latency.

All 18 existing checks pass. Additional checks cover stale queued heartbeat rejection, fresh touch edges, Learn within a packet, an oversized packet split across a message, and eventual terminal diagnostic publication. No external MIDI was sent, no firmware changed, and no physical controller latency was measured.

## Reproduce

Run from `/Users/yassinghobara/Desktop/ContourDJ`. The standalone check avoids a concurrent Package build:

```sh
swiftc -O -warnings-as-errors -swift-version 5 -module-cache-path /private/tmp/contour-midi-module-cache Sources/Contour/MIDIController.swift Tests/MIDIChecks.swift -o /private/tmp/ContourMIDI-after
/private/tmp/ContourMIDI-after
/private/tmp/ContourMIDI-after --benchmark --output=/private/tmp/midi-after.json
/private/tmp/ContourMIDI-after --benchmark --sustained --output=/private/tmp/midi-sustained-after.json
/private/tmp/ContourMIDI-after --queued-benchmark --output=/private/tmp/midi-queued-after.json
cp docs/performance/midi-before-source.swift.txt /private/tmp/Contour-MIDI-before.swift
swiftc -D MIDI_BASELINE -O -swift-version 5 -module-cache-path /private/tmp/contour-midi-module-cache /private/tmp/Contour-MIDI-before.swift Tests/MIDIChecks.swift -o /private/tmp/ContourMIDI-before
/private/tmp/ContourMIDI-before --benchmark --output=/private/tmp/midi-before.json
```

Saved results: `midi-before.json`, `midi-after.json`, `midi-sustained-after.json`, `midi-queued-after.json`, and `midi-comparison.json`. The comparison JSON records source hashes so later changes can be distinguished from this measurement.
