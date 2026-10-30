# YaSushi controller profile

Contour's defaults come from the local controller firmware and its Mixxx mapping. The desktop projects were inspected read only; nothing was flashed. No applicable `AGENTS.md` was found in the requested project roots or their Desktop ancestors. The firmware's own release notes label the hardware **HARDWARE-UNTESTED**, so these are source-derived mappings, not a claim that the assembled controller has passed a bench test.

## Which project contains the DJ hardware

The relevant project is `/Users/yassinghobara/Desktop/Mixxx Controller`. Its `Electronics-SWITCH` revision uses a YD-RP2040/RP2040, two CD4051 analog multiplexers, three 74HC165 button registers, three 74HC595 LED registers, two 1602 LCDs with PCF8574 backpacks, and a relay for peripheral power. Other MUX, THT and V1 revisions have different pin/power arrangements. See [firmware README](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/README.md:3>), especially lines 3–5 and 27–31. The USB descriptor names the device `Ya$ushi Mixxx Controller` and its interface `Ya$ushi Controls`; development VID/PID are 0xCAFE/0x4051, not a production identity ([descriptor](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/usb_descriptors.c:4>), lines 4–15, 28).

The independent `Jog-module-v1` is a second USB MIDI device named `YaSushi Jog`, using an AS5600 angular sensor and an RP2040. It connects separately to the Mac or a USB hub; the mixer's USB device port is not a USB host. See [jog protocol](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/PROTOCOL.md:3>), [descriptor](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/firmware/usb_descriptors.c:32>), and [jog README](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/README.md:98>).

The older [V1 scope](</Users/yassinghobara/Desktop/Mixxx Controller/V1-proof-of-concept.md:7>), lines 7–18, describes passive incremental encoder jogs without touch sensors. The newer AS5600 module has a **press switch**, not a capacitive touch sensor. Contour names the logical state `touch` because it selects scratch mode, but does not claim a touch electrode exists.

## Mixer input map

All mixer inputs use MIDI channel 1 (zero-based channel 0). The firmware emits each analog update as **LSB CC first, then MSB CC**; the LSB offset is 16, rather than the conventional MIDI CC offset of 32. Combine `MSB * 128 + LSB`, divide by **16380**, and clamp to 0…1. Evidence: [main.c](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/main.c:73>), lines 73–76 and 275–285; [Mixxx JS](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/Mixxx-mapping/YaSushi.js:27>), lines 27–35.

| Physical control | MSB / LSB CC, decimal | Contour action |
|---|---|---|
| A high, mid, low EQ | 0/16, 1/17, 2/18 | `deck0.high`, `.mid`, `.low` |
| A filter | 3/19 | `deck0.filter` |
| B high, mid, low EQ | 4/20, 5/21, 6/22 | `deck1.high`, `.mid`, `.low` |
| B filter | 7/23 | `deck1.filter` |
| A / B channel faders | 8/24, 9/25 | `deck0.volume`, `deck1.volume` |
| A / B pitch faders | 10/26, 11/27 | `deck0.rate`, `deck1.rate` |
| Crossfader | 12/28 | `mixer.crossfader` |

Control order is explicit in [README line 29](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/README.md:29>), [scan code lines 99–104](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/main.c:99>), and [mapping lines 5–15](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/Mixxx-mapping/YaSushi.js:5>). The 14-bit wire representation does not establish 14-bit physical ADC accuracy. The firmware uses internal ADC filtering and nominal calibration; actual end stops, polarity, noise and center positions need an assembled controller test.

Notes use velocity 127 for press and zero for release. Contour also accepts real Note Off. Initial/power-off zero-velocity releases do not trigger play, stop, load or navigation. Source: [main.c lines 289–302](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/main.c:289>) and [release notes line 25](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/Release/README.md:25>).

| Physical control | A note | B note | Contour action |
|---|---|---|---|
| PREV | 32 | 42 | `deckN.beatjump`, −4 beats; SHIFT −1 |
| STOP | 33 | 43 | `deckN.stop` |
| PLAY_TOP | 34 | 44 | `deckN.play`; SHIFT `deckN.sync` |
| CUE_TOP | 35 | 45 | `deckN.cue` |
| NEXT | 36 | 46 | `deckN.beatjump`, +4 beats; SHIFT +1 |
| LOOP | 37 | 47 | `deckN.loop` |
| CUE | 38 | 48 | `deckN.cue` |
| PLAY_LOWER | 39 | 49 | `deckN.play`; SHIFT `deckN.sync` |
| FX_OFF | 40 | 50 | `deckN.effectsOff` |
| LOAD | 41 | 51 | `deckN.load` |
| Jog press | 55 | 56 | `deckN.touch` |

Here N is 0 for A and 1 for B. The physical net names/order are in [button schematic](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Source/04_Buttons_Encoders.kicad_sch:20>), lines 20–34, 57–69, 94–104. The mapping behavior is in [JS lines 44–75](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/Mixxx-mapping/YaSushi.js:44>). The firmware inserts browse/jog presses without reordering the original 22 button bits ([main.c lines 107–115](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/main.c:107>)). Two physical cue switches combine with OR semantics so releasing one while the other remains held does not release Cue.

| Other control | Message | Contour action |
|---|---|---|
| SHIFT | Note 52 | Modifier; not an audio command |
| Browser back | Note 53 | `library.back` |
| Browser press | Note 54 | `library.load` |
| A / B passive jog encoder | CC 64 / 65, value 1 or 127 | `deck0.jog` / `deck1.jog`, +1 / −1 step |
| Browser encoder | CC 66, value 1 or 127 | `library.encoder`; SHIFT `library.focus` |

The mixer sends ±1 per configured encoder detent, not an absolute endless knob position ([main.c lines 297–302](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/main.c:297>)). The decoder additionally supports two's-complement magnitudes, ignoring reserved values 0 and 64. SHIFT multiplies Contour's jog steps by five. Contour's cue/sync/stop/jog audio behavior follows its own engine; it does not execute Mixxx's mapping or claim Mixxx's scratch algorithm. Load protection and sound-state decisions belong to the app model.

## Independent AS5600 jog module

| Message | Meaning and Contour handling |
|---|---|
| Channel 1 / 2 | A / B, zero-based deck 0 / 1 |
| CC 32, 1…63 | Positive angular counts |
| CC 32, 65…127 | Negative counts `value − 128` |
| CC 32, 0 or 64 | Ignored |
| Note 64, velocity 127 | Held press, only with a fresh heartbeat |
| Note 64 velocity 0 / Note Off | Release |
| CC 33, value 1 | Firmware heartbeat, expected about every 100 ms |

The source specifies **4096 counts per turn**, a target acquisition interval of 1 ms, and a 500 ms host timeout. The input parser preserves signed counts, then the default mapping scales them by **1/64**, yielding 64 Contour jog steps per turn. This is an initial app sensitivity, editable in `MIDIMapping.scale`; it is not an angular calibration or a promise of vinyl behavior. Motion/positive press requires a heartbeat younger than 500 ms. Missing heartbeat clears held press on the next 100 ms watchdog check or the next jog event, plus main-thread scheduling time. A returning heartbeat does not reconstruct a press. Firmware heartbeat indicates liveness, not magnet health. Evidence: [PROTOCOL.md lines 10–42](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/PROTOCOL.md:10>), [jog_config.h lines 5–25](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/firmware/jog_config.h:5>), and [original host mapping lines 100–165](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/mixxx/YaSushi-Jog.js:100>).

The module pins are SDA4, SCL5, press6 and optional deck selector7, on a separate RP2040 ([jog_config.h](</Users/yassinghobara/Desktop/Mixxx Controller/Jog-module-v1/firmware/jog_config.h:4>)). No motor, force feedback, automatic platter rotation or capacitive sensing is implemented by Contour.

## App integration and remapping

`MIDIController` uses CoreMIDI input ports, discovers sources at startup and on setup notifications, and connects/disconnects them live. Each source has an independent running-status parser. It accepts packet-spanning MIDI messages, ignores SysEx/system-common controls, and preserves real-time interleaving. MIDI callback threads copy bytes; published state and action callbacks run on the main actor.

Default source filters match `Ya$ushi`/`YaSushi` names and distinguish the jog module by `Jog`. Other controllers remain available through Learn. Learn captures source, channel, message type and control number; known mixer MSBs retain their paired-14-bit decoding. Learning a control replaces both its previous assignment and the target action's previous assignments. Reset restores firmware defaults. Mapping encoding is coalesced onto a utility task and flushes on app quit. Saved Codable mappings use the application's `Contour.MIDIMappings.v1` preferences key. `removeMapping` clears one assignment; `updateMapping` edits its fields. Generic endless encoders need the relative mode; a generic CC learned for a non-jog action defaults to 7-bit absolute. There is no automatic inference of arbitrary vendors' relative protocols.

`eventLog` keeps up to 200 sampled activity descriptions, published at up to 20 Hz. Control actions are not discarded. `simulate(action:value:)` exercises app routing without a device; `inject(bytes:source:)` additionally exercises raw byte parsing and firmware mappings. These do not send MIDI. The default mappings cover two physical decks; Learn can bind the contract's deck 2/3 actions. No default hardware button is invented for hotcues 1–8 or master gain because the inspected hardware does not dedicate one.

Firmware can receive VU feedback on CC96/97 and LCD rows as `F0 7D 59 01 deck row [16 ASCII bytes] F7` ([Mixxx JS lines 78–97](</Users/yassinghobara/Desktop/Mixxx Controller/Electronics-SWITCH/Firmware/Mixxx-mapping/YaSushi.js:78>)). This app's current MIDI implementation is input only; it does not drive LEDs/LCDs or forward DIN MIDI.

## Other requested Desktop projects

These were inspected to avoid treating an unrelated encoder as DJ firmware:

| Project | Source observation |
|---|---|
| `Yasushi-V2_3` | Word-to-Fourier drawing device: ESP32-S3 N16R8, ST7789 TFT, KY-040 input; [README lines 6–19 and 65–93](/Users/yassinghobara/Desktop/Yasushi-V2_3/README.md:6). No DJ MIDI protocol identified. |
| `Yasushi.2` | ESP32-S3 Arduino target with USB CDC enabled ([platformio.ini lines 1–13](/Users/yassinghobara/Desktop/Yasushi.2/firmware/platformio.ini:1)); encoder navigates a text keyboard and selects letters ([main.cpp lines 25–65](/Users/yassinghobara/Desktop/Yasushi.2/firmware/src/main.cpp:25)). |
| `sketch_sep18a` | ST7789 image-drawing test; setup prints `Starting image test` and draws an embedded image, then an empty loop ([sketch lines 1229–1266](/Users/yassinghobara/Desktop/sketch_sep18a/sketch_sep18a.ino:1229)). |
| `ORB` | SPI display animation; encoder chooses one of nine states and press pauses animation; serial diagnostics at 115200 ([ORB.ino lines 249–318](/Users/yassinghobara/Desktop/ORB/ORB.ino:249)). |
| `ai-dj` | Magenta MRT2 live-coding extensions for Max/Pd/SuperCollider, with ML model installation instructions ([INSTALL.md lines 1–16, 39–80](/Users/yassinghobara/Desktop/ai-dj/INSTALL.md:1)). No hardware MIDI map identified in the inspected project files. |

Virtual environments, dependency directories, generated builds, datasets and model arrays were excluded from the source search. The conclusions concern the inspected source versions; they do not prove what firmware is currently flashed on any attached board.
