import SwiftUI
import AppKit

@main struct ContourApp: App {
    @StateObject private var model = PerformanceModel()
    @NSApplicationDelegateAdaptor(ContourDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Contour") {
            WorkspaceView(model:model,midi:model.midi)
                .onAppear { delegate.model = model }
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--ui-check") {
                        await model.prepare(); await VisualCheck.run(model)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                        await model.prepare()
                        await SmokeCheck.run(model)
                    }
                }
        }
        .defaultSize(width:1420,height:900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing:.newItem) { Button("Import Audio…") { model.importFiles() }.keyboardShortcut("o") }
            CommandMenu("Deck") {
                ForEach(0..<4,id:\.self) { i in
                    Button("Play / Pause Deck \(["A","B","C","D"][i])") { if i > 1 { model.fourDecks = true };model.togglePlay(i) }.keyboardShortcut(KeyEquivalent(Character(String(i+1))))
                }
                Divider()
                Button("Cue Active Deck") { model.cue(model.activeDeck) }.keyboardShortcut("k")
                Button("Match Active Deck Tempo") { model.matchTempo(model.activeDeck) }.keyboardShortcut("t")
                Button("Toggle Active Deck Loop") { model.toggleLoop(model.activeDeck) }.keyboardShortcut("l")
                Button("Reverse Active Deck") { model.toggleReverse(model.activeDeck) }.keyboardShortcut("r",modifiers:[.command,.shift])
                Divider()
                Button("Stop All Audio") { model.stopAll() }.keyboardShortcut(".")
            }
            CommandMenu("Mix") {
                Button(model.recording ? "Stop Recording" : "Record Master Mix…") { model.toggleRecording() }.keyboardShortcut("r")
                Button("Center Crossfader") { model.setCrossfader(0.5) }.keyboardShortcut("x",modifiers:[.command,.shift])
                Button(model.patternEnabled ? "Stop Rhythm" : "Play Rhythm") { model.patternEnabled.toggle();model.updatePattern() }
                Divider()
                Button("MIDI Controller…") { model.showController = true }.keyboardShortcut("m",modifiers:[.command,.shift])
            }
            CommandGroup(after:.textEditing) {
                Button("Find in Library") { NotificationCenter.default.post(name:.contourFocusSearch,object:nil) }.keyboardShortcut("f")
            }
            CommandGroup(after:.sidebar) {
                Toggle("Four Decks",isOn:Binding(get:{model.fourDecks},set:{model.setFourDecks($0)})).keyboardShortcut("4",modifiers:[.command,.option])
            }
            CommandGroup(replacing:.help) {
                Button("Contour Guide") { let url = Bundle.main.resourceURL?.appendingPathComponent("Guide.html");if let url { NSWorkspace.shared.open(url) } }
                Button("Show Controller Mapping") { model.showController = true }
            }
        }
        Settings { SettingsView(model:model) }
    }
}

@MainActor final class ContourDelegate: NSObject, NSApplicationDelegate {
    weak var model: PerformanceModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply { model?.shutdown();return .terminateNow }
}

struct SettingsView: View {
    @ObservedObject var model: PerformanceModel
    @ObservedObject private var mix:MixControlState
    init(model:PerformanceModel) {self.model=model;self.mix=model.mix}
    var body: some View {
        TabView {
            Form {
                Section("Master Output") {
                    Text("Audio follows the output device selected in macOS Sound settings.").foregroundStyle(.secondary)
                    LabeledContent("Master Level") { Slider(value:Binding(get:{mix.masterVolume},set:{model.setMaster($0)}),in:0...1).frame(width:200).accessibilityLabel("Master output level") }
                    Button("Open Sound Settings…") { if let url = URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) } }
                }
                Section("Playback") {
                    Text("Tempo changes playback speed and pitch together. Match Tempo sets the rate; it does not synchronize beat phase.").font(.caption).foregroundStyle(.secondary)
                    Text("Headphone pre-listening on a separate output and live audio inputs are not available in this build.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Audio",systemImage:"speaker.wave.2") }
            Form {
                Section("USB MIDI") {
                    Text("The built-in profile is derived from your YaSushi firmware: 14-bit faders, buttons, mixer encoders and the separate jog module.")
                    Button("Open MIDI Controller…") { model.showController = true;NSApp.keyWindow?.close() }
                }
                Section("Jog Wheel") { Text("Jog press switches to seek-style scratching. Relative movement otherwise nudges the track. Response needs hands-on calibration with your hardware.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("Controller",systemImage:"pianokeys") }
            Form {
                Section("Contour") {
                    Text("A native mixing workspace for your DIY controller.").font(.headline)
                    Text("Version 0.1.1 · Local Development Build").foregroundStyle(.secondary)
                    Text("Independent software inspired by your workflow. Uses Apple’s native interface frameworks; it is not an Apple or Native Instruments product.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Your Data") {
                    Text("The library references original audio files without copying or modifying them. Cues, BPM edits and mappings save locally.").font(.caption)
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([model.dataDirectory]) }
                }
            }.formStyle(.grouped).tabItem { Label("About",systemImage:"info.circle") }
        }.frame(width:560,height:360)
    }
}

extension Notification.Name { static let contourFocusSearch = Notification.Name("ContourFocusSearch") }
