import SwiftUI
import AppKit

struct WorkspaceView: View {
    @ObservedObject var model: PerformanceModel
    @ObservedObject var midi: MIDIController
    @State private var sidebarVisible = NavigationSplitViewVisibility.all
    @State private var patternPopover = false
    var body: some View {
        NavigationSplitView(columnVisibility:$sidebarVisible) {
            List(selection:$model.section) {
                Section("Collection") {
                    Label("All Tracks",systemImage:"music.note.list").tag("Library")
                    Label("Recently Added",systemImage:"clock").tag("Recent")
                    Label("Recordings",systemImage:"waveform").tag("Recordings")
                }
                Section("Studio") {
                    Button { model.showController = true } label: { Label("MIDI Controller",systemImage:"pianokeys") }.buttonStyle(.plain).padding(.vertical,4)
                    Button { patternPopover = true } label: { Label("Rhythm",systemImage:"metronome") }.buttonStyle(.plain).padding(.vertical,4)
                }
                Section {
                    Text("YaSushi MIDI profile").font(.system(size:11)).foregroundStyle(.secondary).padding(.vertical,8)
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min:160,ideal:180,max:230)
            .safeAreaInset(edge:.bottom) {
                HStack(spacing:6) { Image(systemName:midi.sources.isEmpty ? "cable.connector" : "point.3.connected.trianglepath.dotted");Text(midi.sources.isEmpty ? "No MIDI Input" : "\(midi.sources.count) MIDI Input\(midi.sources.count == 1 ? "" : "s")").lineLimit(1);Spacer(minLength:0) }.font(.system(size:11)).foregroundStyle(.secondary).padding(14)
            }
        } detail: {
            VStack(spacing:0) {
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("Session").font(.system(size:21,weight:.semibold,design:.rounded))
                        Text("\(model.fourDecks ? "Four" : "Two") decks · Local audio").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth:290) }
                    GlobalMixControls(model:model,mix:model.mix,meter:model.meter)
                }.padding(.horizontal,22).padding(.top,18).padding(.bottom,15)
                if model.fourDecks {
                    HStack(spacing:12) {
                        ForEach(model.visibleDecks) { deck in QuickTransport(deck:deck,model:model) }
                        Spacer()
                        CrossfaderControl(model:model,mix:model.mix,width:150)
                    }.padding(.horizontal,22).padding(.bottom,12)
                }
                VSplitView {
                    ScrollView {
                        if model.fourDecks {
                            VStack(spacing:16) {
                                HStack(alignment:.top,spacing:16) { DeckPanel(deck:model.decks[0],model:model);DeckPanel(deck:model.decks[1],model:model) }
                                HStack(alignment:.top,spacing:16) { DeckPanel(deck:model.decks[2],model:model);DeckPanel(deck:model.decks[3],model:model) }
                                MixerPanel(model:model,channels:model.visibleDecks).frame(maxWidth:.infinity)
                            }.padding(.horizontal,20).padding(.bottom,18)
                        } else {
                            HStack(alignment:.top,spacing:14) {
                                DeckPanel(deck:model.decks[0],model:model).frame(maxWidth:.infinity)
                                MixerPanel(model:model,channels:Array(model.decks.prefix(2)))
                                DeckPanel(deck:model.decks[1],model:model).frame(maxWidth:.infinity)
                            }.padding(.horizontal,20).padding(.bottom,18)
                        }
                    }.frame(minHeight:440,idealHeight:500)
                    LibraryView(model:model).frame(minHeight:170,idealHeight:240)
                }
            }
            .background(Color(nsColor:.windowBackgroundColor))
            .navigationTitle("Contour")
            .toolbar {
                ToolbarItemGroup(placement:.primaryAction) {
                    Button { model.importFiles() } label: { Label("Import",systemImage:"plus") }.help("Import Audio · ⌘O")
                    Button { model.setFourDecks(!model.fourDecks) } label: { Label(model.fourDecks ? "Two Decks" : "Four Decks",systemImage:model.fourDecks ? "rectangle.split.2x1" : "rectangle.split.2x2") }.help("Switch between two and four decks")
                    Button { patternPopover.toggle() } label: { Label("Rhythm",systemImage:"metronome") }.help("Rhythm generator").popover(isPresented:$patternPopover) { PatternView(model:model) }
                    Button { model.toggleRecording() } label: { Label(model.recording ? "Stop · \(formatTime(model.recordingSeconds))" : "Record",systemImage:model.recording ? "stop.circle.fill" : "record.circle") }.tint(model.recording ? .red : nil).help("Record the master mix to WAV · ⌘R")
                    Button { model.showController.toggle() } label: { Label("Controller",systemImage:"slider.horizontal.3") }.help("MIDI mapping and input monitor")
                }
            }
        }
        .preferredColorScheme(model.qaAppearance)
        .frame(minWidth:1100,minHeight:740)
        .task { await model.prepare() }
        .sheet(isPresented:$model.showController) { ControllerView(midi:midi) }
        .alert("Contour",isPresented:Binding(get:{model.error != nil},set:{ if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct LibraryView: View {
    @ObservedObject var model: PerformanceModel
    @FocusState private var searchFocused: Bool
    var sorted: [LibraryTrack] { model.filteredTracks }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:model.section == "Recordings" ? "waveform" : "music.note.list").foregroundStyle(.secondary)
                Text(model.section == "Library" ? "Library" : model.section == "Recent" ? "Recently Added" : "Recordings").font(.system(size:13,weight:.semibold))
                Text("\(model.filteredTracks.count) tracks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing:5) { Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Search Library",text:$model.search).textFieldStyle(.plain).focused($searchFocused) }.padding(.horizontal,8).padding(.vertical,6).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:7)).frame(width:190)
                Menu("Load Selected") { ForEach(model.visibleDecks) { d in Button("Deck \(d.letter)") { model.loadSelected(d.id) } } }.disabled(model.selected == nil)
            }.padding(.horizontal,20).padding(.vertical,11)
            if sorted.isEmpty {
                ContentUnavailableView(model.section == "Recordings" ? "Your Mixes Live Here" : "Make Room for Your Music",systemImage:model.section == "Recordings" ? "waveform" : "music.note",description:Text(model.search.isEmpty ? "Import audio files to get started, or play the included demo tracks." : "No tracks match your search."))
            } else {
                Table(sorted,selection:$model.selectedTrack,sortOrder:$model.sortOrder) {
                    TableColumn("Title",value:\.title) { t in
                        HStack(spacing:8) {
                            Image(systemName:t.isRecording ? "waveform" : (t.demo != nil ? "sparkles" : "music.note")).foregroundStyle(.secondary).frame(width:16)
                            Text(t.title).fontWeight(.medium).lineLimit(1)
                            if let d = model.decks.first(where:{$0.trackID == t.id}) { Text(d.letter).font(.system(size:9,weight:.bold)).foregroundStyle(Color.primary).padding(.horizontal,5).padding(.vertical,2).background(d.color.opacity(0.1),in:RoundedRectangle(cornerRadius:3)) }
                        }.contextMenu { ForEach(model.visibleDecks) { d in Button("Load into Deck \(d.letter)") { model.load(t,into:d.id) } }; if let path = t.path { Divider();Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) } } }
                    }.width(min:180,ideal:340)
                    TableColumn("Artist",value:\.artist).width(min:90,ideal:180)
                    TableColumn("BPM",value:\.bpm) { t in Text(t.bpm > 0 ? String(format:"%.1f",t.bpm) : "—").monospacedDigit().foregroundStyle(.secondary) }.width(65)
                    TableColumn("Time",value:\.duration) { t in Text(t.duration > 0 ? formatTime(t.duration) : "—").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("Source") { t in Text(t.demo != nil ? "Demo" : (t.isRecording ? "Recording" : URL(fileURLWithPath:t.path ?? "").pathExtension.uppercased())).font(.caption).foregroundStyle(.secondary) }.width(75)
                }.alternatingRowBackgrounds().contextMenu(forSelectionType:UUID.self) { selection in
                    if let id = selection.first,let t = model.tracks.first(where:{$0.id == id}) { ForEach(model.visibleDecks) { d in Button("Load into Deck \(d.letter)") { model.load(t,into:d.id) } } }
                } primaryAction: { selection in if let id = selection.first,let t = model.tracks.first(where:{$0.id == id}) { model.load(t,into:model.activeDeck) } }
            }
        }.background(Color(nsColor:.controlBackgroundColor))
        .dropDestination(for:URL.self) { urls,_ in model.addFiles(urls);return true }
        .onReceive(NotificationCenter.default.publisher(for:.contourFocusSearch)) { _ in searchFocused = true }
    }
}

struct PatternView: View {
    @ObservedObject var model: PerformanceModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Label("Rhythm",systemImage:"metronome").font(.headline);Spacer();Button(model.patternEnabled ? "Stop" : "Play") { model.patternEnabled.toggle();model.updatePattern() }.buttonStyle(.borderedProminent) }
            Text("A synthesized drum pattern, mixed directly into the master output.").font(.caption).foregroundStyle(.secondary)
            HStack { Text("Tempo");Spacer();Text(String(format:"%.0f BPM",model.patternBPM)).monospacedDigit() }
            Slider(value:$model.patternBPM,in:60...180,step:1).onChange(of:model.patternBPM) { model.updatePattern() }.accessibilityLabel("Rhythm tempo")
            HStack { Text("Level");Slider(value:$model.patternVolume,in:0...0.7).onChange(of:model.patternVolume) { model.updatePattern() }.accessibilityLabel("Rhythm level") }
            Button("Use Active Deck Tempo") { model.patternBPM = model.decks[model.activeDeck].effectiveBPM;model.updatePattern() }.buttonStyle(.borderless)
        }.padding(22).frame(width:320)
    }
}

struct ControllerView: View {
    @ObservedObject var midi: MIDIController
    @Environment(\.dismiss) private var dismiss
    @State private var action = "deck0.play"
    @State private var reset = false
    var actions: [String] { (0..<4).flatMap { d in ["play","cue","stop","volume","low","mid","high","filter","rate","jog","touch","loop","sync","load"].map { "deck\(d).\($0)" } + (1...8).map { "deck\(d).hotcue\($0)" } } + ["mixer.crossfader","mixer.master","library.encoder","library.load"] }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { VStack(alignment:.leading,spacing:4) { Text("Your Controller, Connected").font(.title2.bold());Text("USB MIDI · YaSushi mixer and jog profile").foregroundStyle(.secondary) };Spacer();Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            GroupBox("MIDI Inputs") {
                HStack { VStack(alignment:.leading,spacing:5) { if midi.sources.isEmpty { Text("No MIDI sources detected").foregroundStyle(.secondary);Text("Connect your USB controller, then refresh.").font(.caption).foregroundStyle(.secondary) } else { ForEach(midi.sources,id:\.self) { Label($0,systemImage:"cable.connector") } } };Spacer();Button("Refresh") { midi.refresh() } }.padding(8)
            }
            HStack(spacing:12) {
                Picker("Action",selection:$action) { ForEach(actions,id:\.self) { Text(actionLabel($0)).tag($0) } }.frame(maxWidth:360)
                if midi.isLearning { Button("Cancel Learn") { midi.cancelLearn() };Text("Move one control on your hardware…").font(.caption).foregroundStyle(.secondary) }
                else { Button("Learn MIDI") { midi.learn(action:action) }.buttonStyle(.borderedProminent);Text("Mappings save automatically.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { Text("MAPPINGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary);Spacer();Text("14-bit faders · relative jog encoders").font(.caption).foregroundStyle(.secondary) }
            List(midi.mappings) { mapping in HStack { Text(actionLabel(mapping.action)).frame(width:190,alignment:.leading);Text(mapping.description).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary);Spacer();Button("Learn") { action = mapping.action;midi.learn(action:mapping.action) }.buttonStyle(.borderless); Button { midi.removeMapping(id:mapping.id) } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).help("Remove this mapping").accessibilityLabel("Remove mapping for \(actionLabel(mapping.action))") } }.frame(minHeight:220)
            GroupBox("Recent MIDI Activity") { HStack { Text(midi.lastMessage.isEmpty ? "Waiting for MIDI input…" : midi.lastMessage).font(.system(.caption,design:.monospaced)).textSelection(.enabled);Spacer() }.padding(8).frame(minHeight:26) }
            HStack { Button("Restore YaSushi Profile…") { reset = true };Spacer();Text("Jog press enables seek-style scratching. Hardware feel needs calibration.").font(.caption).foregroundStyle(.secondary).frame(maxWidth:380,alignment:.trailing) }
        }.padding(24).frame(width:780,height:650)
        .confirmationDialog("Replace custom mappings with the YaSushi profile?",isPresented:$reset) { Button("Restore Profile",role:.destructive) { midi.resetMappings() } }
    }
}
func actionLabel(_ action: String) -> String {
    let p = action.split(separator:".");guard p.count == 2 else { return action }
    let names = ["play":"Play / Pause","cue":"Cue","stop":"Stop","volume":"Volume","low":"Low EQ","mid":"Mid EQ","high":"High EQ","filter":"Filter","rate":"Tempo","jog":"Jog","touch":"Jog Press","loop":"Loop","sync":"Match Tempo","load":"Load Track","crossfader":"Crossfader","master":"Master Level","encoder":"Browse","beatjump":"Beatjump","effectsOff":"Effects Off"]
    let head: String
    if p[0].hasPrefix("deck"),let n = Int(p[0].dropFirst(4)),(0..<4).contains(n) { head = "Deck \(["A","B","C","D"][n])" } else { head = String(p[0]).capitalized }
    return head + " · " + (names[String(p[1])] ?? String(p[1]).capitalized)
}

struct QuickTransport: View {
    @ObservedObject var deck:DeckState
    @ObservedObject var model:PerformanceModel
    @ObservedObject private var clock:DeckClock
    init(deck:DeckState,model:PerformanceModel) {self.deck=deck;self.model=model;self.clock=deck.clock}
    var body:some View {
        Button { model.togglePlay(deck.id) } label:{
            HStack(spacing:6) { Text(deck.letter).fontWeight(.bold);Image(systemName:deck.playing ? "pause.fill" : "play.fill");Text(formatTime(clock.position)).monospacedDigit() }
        }.disabled(!deck.loaded).accessibilityLabel("Deck \(deck.letter), \(deck.playing ? "playing, pause" : "paused, play")")
    }
}
