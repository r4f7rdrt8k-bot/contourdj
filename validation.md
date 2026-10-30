# Validation — 25 October 2026, Cairo

## Audio core

`./scripts/test-core.sh` compiles the C++ engine and standalone test harness with the installed Clang toolchain. All 14 cases pass. ASan/UBSan also pass with no reported findings. The suite covers stereo/crossfader routing, loop bounds, reverse position/sample order, rate, EQ/filter attenuation, echo, all effects changing the signal without non-finite output, pattern recording, four decks/natural end, concurrent load/reclaim, bounded overflow and invalid controls. Instrumentation counted zero C++ allocations/deallocations inside render; it does not interpose every libc allocator. Ten seconds of synthetic output rendered faster than real time, without certifying hardware latency or dropout-free live use.

See `core-test-results.json` and `core-test-results-asan.json`. The CLT-only environment lacks XCTest, so the maintained runnable tests use the standalone harness rather than requiring full Xcode.

## MIDI

`./scripts/test-midi.sh` checks the actual Swift parser/controller. Eighteen grouped assertions passed. Source enumeration returned no connected inputs. These tests exercise byte injection and action routing, not USB electrical behavior, firmware flashing, knob noise, real wheel feel, physical latency, LEDs or LCDs. The default profile is derived from the local project sources linked in `hardware-profile.md`.

## Packaged-app integration

The release app ran with `CONTOUR_DATA_DIR` pointing inside this workspace. No personal media or personal Traktor collection was used. `--smoke-test` played original synthetic demo tracks, routed MIDI actions, recalled a Hotcue, enabled looping, changed rate/EQ/effect/pattern state and finalized an actual stereo 48 kHz PCM16 WAV. All seven generated codec fixtures also loaded with 40-second durations, 120 estimated BPM and nonzero waveforms. `app-smoke-test.json` is the full result.

The initial import check exposed an EOF read bug; the decoder now checks the remaining source frames before reading. The final packaged-app test supersedes that failed historical check. Codec services need normal macOS access; the tool sandbox denied some system codec services, while normal local app execution decoded all seven fixtures. No media bytes were modified by the app.

## Interface

The app's own NSView bitmap renderer captured two-deck light, compact, and four-deck dark layouts. The deck workspace, native controls, library table and appearance changes were inspected. Compact areas can scroll to secondary controls; the master volume and crossfader remain in the workspace header. Four-deck mode has fixed quick-transport controls, and reducing to two decks is blocked while C/D play.

The computer-use app selector timed out. Own-window bitmap capture omits native vibrancy/sidebar content and the toolbar/titlebar, so it cannot certify those rendered surfaces or actual mouse/VoiceOver interactions. Code review checked standard menus/file panels/Settings, labels, slider ranges, shared library/MIDI sorting and focus-safe shortcuts. Full Keyboard Access, VoiceOver, enlarged-text behavior and real hardware operation remain manual checks.

## Delivery

The ARM64 app is locally ad-hoc signed with bundle ID `com.contourdj.desktop`, minimum macOS 14. The source and repeatable build script accompany it. The two demo tracks load paused; the app does not start playback on launch. Normal launch stores its own library/preparation under Application Support/Contour; MIDI mappings use its own preferences domain. Original media is referenced without tag writes. See README for the implemented scope and limits.

## Performance follow-up

The optimized 0.1.1 release passed the same playback/recording/seven-format smoke checks, extended MIDI tests and model/cache/persistence regression checks. [Performance report](performance/README.md) contains frozen baselines, repeated app CPU measurements and subsystem comparisons.
