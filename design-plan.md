# Contour design plan

Native macOS 14+ performance workspace for DJs mixing local tracks. The thesis is to keep the next transport decision, the audible mix, and the library visible together. This is an implementation target; passing checks, rather than this plan, establish delivered behavior.

## Foundations and craft

Use the installed `apple-design` skill. References read: `accessibility.md`, `layout.md`, `typography.md`, `color.md`, `designing-for-macos.md`, `windows.md`, `the-menu-bar.md`, `toolbars.md`, `settings.md`, `lists-and-tables.md`, and `keyboards.md`, under `/Users/yassinghobara/.codex/skills/apple-design/references/hig/`.

The implemented signature is each track’s actual full-length audio envelope with a moving playhead, saved cue markers, and a highlighted loop range. Deck letters, elapsed/remaining time, and explicit transport labels remain visible. A future zoomed, scrolling waveform view could use a fixed central playhead; stacked phase-aligned views require timing work and are not represented as delivered. Omit decorative album-art heroes and imitation hardware screws. The density belongs to a performance instrument, while windowing, menus, tables, and settings retain Mac conventions. These are product judgments.

`layout.md › Visual hierarchy`: “Group related items to clearly express related information or functions.” Keep each deck’s transport, cues, rate, and loop controls together; give the mixer a stable location. Use 4/8/12/16/24 pt spacing, 8 pt local corner radii, and system separators; avoid wrapping every knob in a separate card.

## Color and typography

Use `NSColor.windowBackgroundColor`, `controlBackgroundColor`, `labelColor`, `secondaryLabelColor`, `controlAccentColor`, and system status colors first. Follow the system appearance. Fallback colors below are explicit, opaque artwork tokens for custom drawing; they are not fixed replacements for dynamic system colors.

| Role | Light fallback on #F5F5F7 | Dark fallback on #1C1C1E |
| --- | --- | --- |
| Surface | #F5F5F7 | #1C1C1E |
| Primary content | #1D1D1F · 15.46:1 | #F5F5F7 · 15.63:1 |
| Secondary content | #5D5D64 · 6.00:1 | #B4B4BC · 8.26:1 |
| Action / selected waveform | #0058B0 · 6.38:1 | #7DBBFF · 8.45:1 |
| Warning / approaching end | #9A3A00 · 6.47:1 | #FFB477 · 9.76:1 |
| Error / clip indicator | #BA1A1A · 5.93:1 | #FF8A80 · 7.45:1 |

Ratios were calculated using WCAG relative luminance on the listed solid surfaces. Recompute for actual compositing, selected rows, disabled states, and Increase Contrast. Small text requires 4.5:1; meaningful nontext controls require 3:1. Color supplements “Playing”, “Paused”, “Clip”, and A–D labels. `accessibility.md › Vision`: “Prefer system-defined colors.”

Use SF Pro via SwiftUI system fonts: 20 pt semibold deck title, 17 pt semibold section heading, 13 pt body/control/table text, 11 pt secondary metadata. Use monospaced digits at 24 pt semibold for time and 17 pt medium for BPM. Do not shrink actionable labels below 13 pt to fit four decks. Use SF Symbols with accessible names for standard actions. `typography.md › Platform considerations › Desktop (macOS)` identifies SF Pro as the Mac system font and notes macOS does not support Dynamic Type; provide layout room for larger accessibility display text instead of assuming iOS scaling.

## Responsive workspace

Current layout: two deck panels flank the mixer; four-deck mode uses a 2×2 deck workspace with the mixer below. The resizable library occupies a lower pane in both modes. Window minimum is 1100×740 pt. The compact selected-deck arrangement below is a future refinement, not an implemented adaptive layout. Dimensions are product targets, not Apple requirements. Vertical scrolling is preferable to clipped controls.

```text
CURRENT · two decks                  CURRENT · four decks
┌ native toolbar: Import / 2–4 / Search / Record ┐
│ A deck │ A/B mixer │ B deck                  │
│ [Four decks: A/B row, C/D row, A–D mixer]     │
├──────────────────────────────────────────────┤
│ Sources sidebar │ Search + Library table    │
│                 │ sortable rows; load A–D   │
└──────────────────────────────────────────────┘
FUTURE COMPACT · both modes
┌ native toolbar / search / deck count ────────┐
│ A / B / [C / D]: waveform + time + Play/Cue  │
│ Selected deck: rate · hotcues · loop · FX    │
├─────────────────────────┬───────────────────┤
│ Title / Artist / BPM    │ channel faders    │
│ Library table          │ selected EQ/filter│
│                        │ crossfader/master │
└─────────────────────────┴───────────────────┘
```

In two-deck mode, only A/B need workspace rows. Switching layout must not pause, unload, reset levels, or silently stop a hidden deck; require C/D to be stopped before reducing to two decks, or retain explicit C/D playing controls. Save window size, selected layout, and library sort. The table should use native selection, resizable columns, sort headings, and alternating rows; `lists-and-tables.md › Platform considerations › Desktop (macOS)`: “Let people resize columns.”

## Native operation and accessibility

Use native titlebar traffic lights, fullscreen, toolbar, menu bar, file picker, and a separate `Settings` scene. The toolbar holds Import, deck layout, search, MIDI Learn, and Record; frequent per-deck controls stay next to their audio. Standard toolbar material is appropriate; waveform, table, and mixer content use opaque surfaces.

Provide File > Import (⌘O), Edit with standard text commands, View > Two/Four Decks, Deck > Play/Pause/Cue/Load Selected/Loop, Mix > Start/Stop Recording, Window, and Help. Use ⌘F for search, ⌘, for Settings, and the standard fullscreen command. Expose every toolbar action in menus; avoid transport interception while a text field is editing. Keyboard transport bindings must be discoverable and configurable, with selected-deck context announced.

Current Settings groups are Audio, Controller, and About; a future Library group should contain actual supported maintenance options. Show current device information only when queried from the audio system. Do not offer unimplemented output routing, key lock, or synchronization toggles. Layout belongs in View, appearance follows macOS, and no device firmware action is part of setup. `settings.md › General settings`: “Put general, infrequently changed settings in your custom settings area.” Master level is a frequent task control and should be reachable in the workspace as well as Audio settings.

Use native Button/Slider/Picker/Table where possible. Give every custom control a deck-specific label, value, and unit: “Deck A volume, 75 percent”; “Deck B low EQ, minus 3 decibels”. Sliders support keyboard adjustment and visible values; jog/waveform drag has seek/nudge alternatives. Targets are at least 28×28 pt by default, with separated controls. Focus order follows toolbar → decks → library → mixer. VoiceOver should not announce the playhead at display refresh rate. Reduce Motion removes decorative transitions; Reduce Transparency produces opaque chrome. Meter peaks retain a numeric/text alternative.

## Acceptance checks

- At 1440×960 and the supported 1100×740 minimum, both deck layouts have reachable transport, recording state, master level, and library loading; no overlapping controls at enlarged text settings. The 1080×760 compact proposal remains future work.
- With VoiceOver and Full Keyboard Access, import, search, select, load, play, seek, set level, loop, and stop recording without a pointer; focus is visible and no shortcut fires while typing a search.
- Check actual light/dark/Increase Contrast colors against the ratios above; all playing/recording/error states remain recognizable in grayscale.
- Switching layout preserves positions and mixer values; reducing the visible deck count cannot silently lose access to a sounding deck.
