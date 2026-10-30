# Contour feature roadmap

Contour is an independent native Mac DJ application. This roadmap uses the local [Traktor feature analysis](../../Traktor-Pro-4-Analysis/README.md) and [coverage limits](../../Traktor-Pro-4-Analysis/coverage.md) to identify workflows; it does not reuse Traktor binaries, models, branding, or controller source.

The analysis catalogs 120 overlapping capabilities across 19 categories. Its static and manual evidence is broader than its runtime validation: nine areas remain partial, one pending, and three deferred. Neither documented Traktor behavior nor a Contour UI control establishes a verified Contour feature. A substantial first build can cover the core local mixing workflow; complete Traktor parity requires later DSP, data, device, and timing work.

## First-build targets

These are acceptance targets, not a declaration that implementation or testing is complete. The delivered README and test evidence must identify the actual working subset.

| Area | First-build target | Evidence required before claiming delivered |
| --- | --- | --- |
| Native workspace | SwiftUI/AppKit window, two/four-deck layouts, real waveform envelope, native table/search/menus/settings | Resize and keyboard checks in both appearances; layout changes retain audio state |
| Local library | Import user-selected files; title/artist/duration; search/sort; selected-track loading; persisted library metadata | Reopen with a small disposable library and verify order, search and missing-file feedback |
| Audio transport | Independent local playback on at least two decks; play/pause, source-time seek, rate change, reverse, prototype jog | Deterministic fixture render and hardware listening smoke test; explicit format-by-format results |
| Four decks | Four independent audio paths, with C/D loading and transport | Four distinct fixtures audible in one render, correct per-deck controls, no silent two-deck fallback |
| Mixing | Channel volume, three-band EQ, filter, crossfader, master level and meters | Render fixtures to prove gain, EQ/filter response, crossfader endpoints, finite unclipped output at documented levels |
| Preparation | Estimated BPM, eight hotcue positions, basic time/beat-sized loop | Label BPM estimates; prove cue recall, loop boundaries, persistence; no phase-lock claim |
| Effects | Original echo/reverb/flanger implementations with bypass/mix | Render impulse/steady fixtures; prove processing, bounded tails, bypass and persisted UI values |
| Pattern | Basic original synthesized rhythm, tempo and level | Nonzero rendered output with decks stopped; verify start/stop and recorded feed |
| Recording | Stereo internal master recording to a chosen local WAV | Nonzero stereo file, correct duration/rate, openable after stop, expected source signal |
| MIDI | CoreMIDI input enumeration, learnable saved mappings, action routing, test simulation | Parser/routing tests; real-device receipt and learned controls recorded separately |

The transport contract initially changes playback speed and pitch together. Label a simple rate-copy action **Match Tempo**, rather than **Sync**; it does not align beats or track variable tempo. Scratch/jog is a seek/nudge prototype until latency, continuity, and controller behavior are measured. Never imply support from a disabled or decorative button.

## Advanced gaps and release gates

| Later work | Why it is separate | Acceptance gate |
| --- | --- | --- |
| Key lock, phase Sync, flexible beatgrids, quantized cues/loops, Flux/Freeze | Requires time stretching, beat-phase model, scheduled transport and grid editing | Constant/variable-tempo fixture matrix measures phase error, boundary continuity and pitch preservation |
| Stem separation and stem decks | No separated audio or inference model is in the first-build contract | Licensed model/source pipeline; measurable output stems, mute/filter routing, cancellation and quality evaluation |
| Remix Decks and advanced sequencer | Sample banks, capture, one-shots, swing and quantization are more than a drum generator | Save/reload a set, trigger every slot mode, and verify scheduled output against an audio reference |
| FX/model parity and master dynamics | A few original effects do not reproduce 43 named Traktor FX, its EQ models, or Ozone | Independent implementations; response and state-preservation tests for each advertised processor |
| Pro audio routing and monitoring | Default stereo output does not provide separate headphone cue, external mix, inputs or microphone routing | Known multichannel interface; channel identification, latency and reconnect tests; measured headroom |
| Controller profiles, displays, LEDs, soft takeover, touch and jog behavior | Generic MIDI receipt does not certify a controller; device families differ | Exact device/firmware test matrix with real input/output; no firmware flashing |
| DVS | Timecode decoding, calibration and low-latency tracking require dedicated input work | Licensed/known control signal; absolute/relative tracking, dropout and calibration tests |
| Link/MIDI Clock | External clock transport and audio playback have different timing models | Known peer, start/stop and drift measurement; never describe a network clock as audio transport |
| Streaming, offline access and account workflows | Requires service agreements, authentication and restrictions | Authorized service integration, explicit recording/export restrictions, supported plan matrix |
| NML/TSI/TRAK interchange, Smartlists and collection maintenance | Native JSON persistence is not equivalent to Traktor formats | Documented parsing/round-trip fixtures and failure recovery without modifying source audio |
| Broadcasting, loop recorder and automatic playlist mixing | Independent audio/network/session workflows | Local server or deterministic recording tests; duration, recovery and transition evidence |

## Validation and delivery policy

1. Build and run the native `.app`; unit tests alone do not prove output devices or UI operation. Record macOS version, build identifier and test fixture hashes.
2. Separate automated DSP/render results, UI smoke checks, hardware tests, and listening assessment. A simulated MIDI event is never a successful connected-controller test.
3. Keep source tracks unchanged. Exercise import, analysis, cues and persistence using disposable media before testing a personal library; report supported formats individually rather than inheriting Traktor’s list.
4. Run a sustained multideck playback/recording test and report CPU, memory, duration, glitches and the exact output device. Performance, latency and live-performance suitability remain unverified until measured.
5. Expose only implemented actions. Show actionable loading/errors inline, identify BPM as estimated, and publish remaining gaps alongside the build so users can assess it accurately.
