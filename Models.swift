import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct LibraryTrack: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var artist: String
    var path: String?
    var demo: Int?
    var duration: Double = 0
    var bpm: Double = 0
    var added = Date()
    var isRecording = false
}

struct SavedPreparation: Codable, Sendable {
    var cue: Double = 0
    var hotcues: [Double?] = Array(repeating: nil, count: 8)
    var bpm: Double = 120
}

@MainActor final class DeckState: ObservableObject, Identifiable {
    let id: Int
    @Published var trackID: UUID?
    @Published var title = "Load a track"
    @Published var artist = "Choose from your library or drop an audio file"
    @Published var duration: Double = 0
    @Published var bpm: Double = 120
    @Published var waveform: [Float] = [] { didSet { waveformRevision &+= 1 } }
    private(set) var waveformRevision: UInt64 = 0
    let clock = DeckClock()
    var position: Double { get { clock.position } set { clock.update(newValue) } }
    @Published var playing = false
    @Published var loading = false
    @Published var volume: Double = 0.8
    @Published var low: Double = 0
    @Published var mid: Double = 0
    @Published var high: Double = 0
    @Published var filter: Double = 0
    @Published var rate: Double = 1
    @Published var effect: Int = 0
    @Published var effectMix: Double = 0.25
    @Published var cue: Double = 0
    @Published var hotcues: [Double?] = Array(repeating: nil, count: 8)
    @Published var loopBeats: Double = 4
    @Published var looping = false
    @Published var loopStart: Double = 0
    @Published var loopEnd: Double = 0
    @Published var reversed = false
    var touch = false
    init(_ id: Int) { self.id = id }
    var letter: String { ["A", "B", "C", "D"][id] }
    private static let colors: [Color] = [.blue, Color(nsColor:NSColor(name:nil,dynamicProvider:{ appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(calibratedRed:1,green:0.706,blue:0.467,alpha:1) : NSColor(calibratedRed:0.604,green:0.227,blue:0,alpha:1)
    })), .purple, .teal]
    var color: Color { Self.colors[id] }
    var effectiveBPM: Double { bpm * rate }
    var loaded: Bool { duration > 0 }
    var timeRemaining: Double { max(0, duration - position) }
}

@MainActor final class PerformanceModel: ObservableObject {
    let audio = DJAudioEngine()
    let midi = MIDIController()
    let decks = (0..<4).map(DeckState.init)
    @Published var tracks: [LibraryTrack] = [] { didSet { invalidateLibrary() } }
    @Published var selectedTrack: UUID?
    @Published var section = "Library" { didSet { sortOrder = section == "Recent" ? [KeyPathComparator(\LibraryTrack.added,order:.reverse)] : [KeyPathComparator(\LibraryTrack.title)] } }
    @Published var sortOrder = [KeyPathComparator(\LibraryTrack.title)] { didSet { invalidateLibrary() } }
    @Published var search = "" { didSet { invalidateLibrary() } }
    @Published var activeDeck = 0
    @Published var fourDecks = false
    let mix = MixControlState()
    let meter = MasterMeterState()
    var crossfader: Double { get { mix.crossfader } set { if mix.crossfader != newValue { mix.crossfader = newValue } } }
    var masterVolume: Double { get { mix.masterVolume } set { if mix.masterVolume != newValue { mix.masterVolume = newValue } } }
    var masterPeak: Float { get { meter.peak } set { meter.update(newValue) } }
    @Published var recording = false
    @Published var recordingSeconds: Double = 0
    @Published var showController = false
    @Published var error: String?
    @Published var notice: String?
    @Published var patternEnabled = false
    @Published var patternBPM: Double = 120
    @Published var patternVolume: Double = 0.35
    @Published var ready = false
    @Published var qaAppearance: ColorScheme? = nil
    private var preparation: [String: SavedPreparation] = [:]
    private var libraryRevision: UInt64 = 0
    private var cachedLibraryRevision = UInt64.max
    private var cachedLibrary: [LibraryTrack] = []
    private var cachedIndices: [UUID:Int] = [:]
    private lazy var persistence = ModelPersistence(directory:dataDirectory)
    private var preparing = false
    private var loadedPaths: [Int: String] = [:]
    private var recordingStarted: Date?
    private var recordingPath: URL?
    private var noticeTime = Date.distantPast
    let dataDirectory: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["CONTOUR_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Contour", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("library.json")), let values = try? JSONDecoder().decode([LibraryTrack].self, from: data) { tracks = values }
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("preparation.json")), let values = try? JSONDecoder().decode([String: SavedPreparation].self, from: data) { preparation = values }
        midi.onAction = { [weak self] action, value in self?.handleMIDI(action, value) }
        audio.onPoll = { [weak self] in self?.tick() }

    }

    var visibleDecks: [DeckState] { Array(decks.prefix(fourDecks ? 4 : 2)) }
    private func invalidateLibrary() { libraryRevision &+= 1 }
    var filteredTracks: [LibraryTrack] {
        if cachedLibraryRevision == libraryRevision { return cachedLibrary }
        let base = tracks.filter { section != "Recordings" || $0.isRecording }
        let filtered = search.isEmpty ? base : base.filter { ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }
        cachedLibrary = filtered.sorted(using:sortOrder)
        cachedIndices = Dictionary(uniqueKeysWithValues:cachedLibrary.enumerated().map { ($0.element.id,$0.offset) })
        cachedLibraryRevision = libraryRevision
        return cachedLibrary
    }
    var selected: LibraryTrack? { tracks.first { $0.id == selectedTrack } }

    func prepare() async {
        guard !ready else { return }
        if preparing { while preparing { try? await Task.sleep(nanoseconds:50_000_000) }; return }
        preparing = true
        defer { preparing = false; ready = true }
        do {
            try audio.start(); audio.setMasterVolume(masterVolume); audio.setCrossfader(crossfader)
            for i in 0..<2 {
                let analysis = try await audio.loadDemo(deck: i)
                let index = tracks.firstIndex { $0.demo == i }
                var track = index.map { tracks[$0] } ?? LibraryTrack(title: analysis.title, artist: analysis.artist, demo: i)
                track.title = analysis.title; track.artist = analysis.artist; track.duration = analysis.duration; track.bpm = analysis.bpm
                if let index { tracks[index] = track } else { tracks.append(track) }
                apply(analysis, track: track, deck: i)
            }
            selectedTrack = tracks.first?.id
            save()
        } catch { self.error = "Audio could not start: \(error.localizedDescription)" }
    }

    func apply(_ analysis: TrackAnalysis, track: LibraryTrack, deck: Int) {
        let d = decks[deck]
        d.trackID = track.id; d.title = analysis.title; d.artist = analysis.artist.isEmpty ? "Local audio" : analysis.artist
        d.duration = analysis.duration; d.bpm = analysis.bpm; d.waveform = analysis.waveform; d.position = 0
        d.playing = false; d.looping = false; d.reversed = false; d.rate = 1
        let key = track.path ?? "demo:\(track.demo ?? deck)"; loadedPaths[deck] = key
        let prep = preparation[key] ?? SavedPreparation(bpm: analysis.bpm)
        d.cue = min(prep.cue, analysis.duration); d.hotcues = Array((prep.hotcues + Array(repeating: nil, count: 8)).prefix(8))
        if prep.bpm > 0 { d.bpm = prep.bpm }
        audio.setRate(deck: deck, rate: 1); audio.setReverse(deck: deck, enabled: false); audio.setVolume(deck: deck, volume: d.volume)
        updateEQ(deck); updateEffect(deck); audio.setFilter(deck: deck, value: d.filter)
    }

    func load(_ track: LibraryTrack, into deck: Int) {
        let d = decks[deck]
        guard !d.loading else { return }
        if d.playing { announce("Pause Deck \(d.letter) before replacing its track."); return }
        persistPreparation(deck); d.loading = true; if activeDeck != deck { activeDeck = deck }
        Task {
            defer { d.loading = false }
            do {
                let analysis: TrackAnalysis
                if track.demo != nil { analysis = try await audio.loadDemo(deck: deck, variant: track.demo) }
                else if let path = track.path { analysis = try await audio.load(url: URL(fileURLWithPath: path), deck: deck) }
                else { return }
                apply(analysis, track: track, deck: deck)
                if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i].duration = analysis.duration; tracks[i].bpm = analysis.bpm; tracks[i].artist = analysis.artist.isEmpty ? tracks[i].artist : analysis.artist }
                save()
            } catch { self.error = "Could not load \(track.title). \(error.localizedDescription)" }
        }
    }

    func importFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]; panel.message = "Add audio to your library. Original files stay where they are."
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func addFiles(_ urls: [URL], loadInto deck: Int? = nil) {
        var first: LibraryTrack?
        for url in urls {
            if let existing = tracks.first(where: { $0.path == url.path }) { if first == nil { first = existing }; continue }
            guard url.isFileURL else { continue }
            let track = LibraryTrack(title: url.deletingPathExtension().lastPathComponent, artist: "Local audio", path: url.path)
            tracks.append(track); if first == nil { first = track }
        }
        selectedTrack = first?.id; save()
        if let deck, let first { load(first, into: deck) }
    }
    func setFourDecks(_ enabled: Bool) {
        if !enabled && decks.dropFirst(2).contains(where: { $0.playing }) { announce("Pause Decks C and D before switching to two decks."); return }
        if fourDecks != enabled { fourDecks = enabled }
    }
    func loadSelected(_ deck: Int) { if let selected { load(selected, into: deck) } }
    func togglePlay(_ deck: Int) {
        let d = decks[deck]; if activeDeck != deck { activeDeck = deck }; guard d.loaded, !d.loading else { return }
        if d.playing { audio.pause(deck: deck); d.playing = false }
        else { if !d.reversed && d.position >= d.duration - 0.01 { audio.seek(deck: deck, seconds: 0) }; audio.play(deck: deck); d.playing = true }
    }
    func stop(_ deck: Int) { audio.pause(deck: deck); decks[deck].playing = false; seek(deck, to: 0) }
    func stopAll() { for d in decks { audio.pause(deck: d.id); d.playing = false }; patternEnabled = false; updatePattern() }
    func seek(_ deck: Int, to seconds: Double) { let d = decks[deck]; guard d.loaded else { return }; let s = min(max(seconds, 0), d.duration); audio.seek(deck: deck, seconds: s); d.position = s }
    func cue(_ deck: Int) { let d = decks[deck]; guard d.loaded else { return }; if d.playing { audio.pause(deck: deck); d.playing = false; seek(deck, to: d.cue) } else { d.cue = d.position; persistPreparation(deck); announce("Deck \(d.letter) cue set at \(formatTime(d.cue)).") } }
    func triggerHotcue(_ deck: Int, slot: Int, clear: Bool = false) {
        let d = decks[deck]; guard d.loaded, (0..<8).contains(slot) else { return }
        if clear { d.hotcues[slot] = nil; persistPreparation(deck); return }
        if let time = d.hotcues[slot] { seek(deck, to: time) }
        else { d.hotcues[slot] = d.position; persistPreparation(deck) }
    }
    func setRate(_ deck: Int, _ value: Double) { decks[deck].rate = min(1.5, max(0.5, value)); audio.setRate(deck: deck, rate: decks[deck].rate) }
    func matchTempo(_ deck: Int) {
        let target = decks[deck]; let other = decks[deck == 0 ? 1 : 0]; guard target.loaded, other.loaded else { return }
        setRate(deck, other.effectiveBPM / max(1, target.bpm)); announce("Deck \(target.letter) tempo matched. Beat phase is unchanged.")
    }
    func changeBPM(_ deck: Int, _ value: Double) { guard value.isFinite, value >= 30, value <= 300 else { return }; decks[deck].bpm = value; persistPreparation(deck); if decks[deck].looping { decks[deck].looping = false; toggleLoop(deck) } }
    func toggleLoop(_ deck: Int) {
        let d = decks[deck]; guard d.loaded else { return }
        d.looping.toggle()
        if d.looping { let beat = 60 / max(1, d.bpm); d.loopStart = floor(d.position / beat) * beat; d.loopEnd = min(d.duration, d.loopStart + beat * d.loopBeats); if d.loopEnd - d.loopStart < 0.01 { d.looping = false } }
        audio.setLoop(deck: deck, start: d.loopStart, end: d.loopEnd, enabled: d.looping)
    }
    func changeLoopLength(_ deck: Int, _ value: Double) { let d = decks[deck]; d.loopBeats = value; if d.looping { d.loopEnd = min(d.duration, d.loopStart + 60 / max(1,d.bpm) * value); audio.setLoop(deck: deck, start: d.loopStart, end: d.loopEnd, enabled: true) } }
    func beatjump(_ deck: Int, beats: Double) { seek(deck, to: decks[deck].position + 60 / max(1,decks[deck].bpm) * beats) }
    func setVolume(_ deck: Int, _ value: Double) { decks[deck].volume = value; audio.setVolume(deck: deck, volume: value) }
    func updateEQ(_ deck: Int) { let d = decks[deck]; audio.setEQ(deck: deck, low: d.low, mid: d.mid, high: d.high) }
    func updateEffect(_ deck: Int) { let d = decks[deck]; audio.setEffect(deck: deck, kind: d.effect, mix: d.effectMix) }
    func updatePattern() { audio.setPattern(enabled: patternEnabled, bpm: patternBPM, volume: patternVolume) }
    func setCrossfader(_ value: Double) { crossfader = value; audio.setCrossfader(value) }
    func setMaster(_ value: Double) { masterVolume = value; audio.setMasterVolume(value) }
    func toggleReverse(_ deck: Int) { decks[deck].reversed.toggle(); audio.setReverse(deck: deck, enabled: decks[deck].reversed) }
    func tick() {
        for d in decks where d.loaded { let pos = audio.position(deck: d.id); if pos.isFinite { d.position = min(d.duration,max(0,pos)) }; if d.playing && ((!d.reversed && d.position >= d.duration - 0.001) || (d.reversed && d.position <= 0)) && !d.looping { d.playing = false } }
        masterPeak = audio.masterPeak
        if recording, let start = recordingStarted { let elapsed = Date().timeIntervalSince(start); if Int(elapsed) != Int(recordingSeconds) { recordingSeconds = elapsed } }
        if let message = audio.errorMessage { error = message; audio.errorMessage = nil }
        if notice != nil && Date().timeIntervalSince(noticeTime) > 5 { notice = nil }
    }
    func announce(_ message: String) { notice = message; noticeTime = Date() }

    func toggleRecording() {
        if recording { finishRecording(); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]; panel.nameFieldStringValue = "Contour Mix \(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).wav"; panel.message = "Record the master mix as a WAV file."
        if panel.runModal() == .OK, let url = panel.url { beginRecording(url) }
    }
    func beginRecording(_ url: URL) {
        do { try audio.startRecording(url: url); recordingPath = url; recordingStarted = Date(); recordingSeconds = 0; recording = true }
        catch { self.error = "Recording could not start: \(error.localizedDescription)" }
    }
    func finishRecording() {
        guard recording else { return }; if let started = recordingStarted { recordingSeconds = Date().timeIntervalSince(started) }; audio.stopRecording(); recording = false
        if let url = recordingPath { let t = LibraryTrack(title: url.deletingPathExtension().lastPathComponent, artist: "Recorded in Contour", path: url.path, duration: recordingSeconds, isRecording: true); tracks.append(t); save(); announce("Recording saved to \(url.lastPathComponent).") }
        recordingPath = nil; recordingStarted = nil
    }
    func handleMIDI(_ action: String, _ value: Double) {
        guard value.isFinite else { return }
        if action == "mixer.crossfader" { setCrossfader(min(1,max(0,value))); return }
        if action == "mixer.master" { setMaster(min(1,max(0,value))); return }
        if action == "library.encoder" { let list = filteredTracks; guard !list.isEmpty else { return }; let i = selectedTrack.flatMap { cachedIndices[$0] } ?? 0; let next = min(list.count-1,max(0,i + (value > 0 ? 1 : -1))); selectedTrack = list[next].id; return }
        if action == "library.load" && value > 0 { loadSelected(activeDeck); return }
        if action == "library.back" && value > 0 { section = "Library"; return }
        let parts = action.split(separator: "."); guard parts.count == 2, parts[0].hasPrefix("deck"), let index = Int(parts[0].dropFirst(4)), decks.indices.contains(index) else { return }
        let d = decks[index]; let command = String(parts[1]); if activeDeck != index { activeDeck = index }
        if index > 1 && !fourDecks { fourDecks = true }
        switch command {
        case "play": if value > 0 { togglePlay(index) }
        case "cue": if value > 0 { cue(index) }
        case "stop": if value > 0 { stop(index) }
        case "load": if value > 0 { loadSelected(index) }
        case "volume": setVolume(index,min(1,max(0,value)))
        case "low": d.low = value*36-24; updateEQ(index)
        case "mid": d.mid = value*36-24; updateEQ(index)
        case "high": d.high = value*36-24; updateEQ(index)
        case "filter": d.filter = value*2-1; audio.setFilter(deck:index,value:d.filter)
        case "rate": setRate(index, 1 + (value-0.5)*0.32)
        case "sync": if value > 0 { matchTempo(index) }
        case "effectsOff": if value > 0 { d.effect = 0; updateEffect(index) }
        case "loop": if value > 0 { toggleLoop(index) }
        case "beatjump": beatjump(index,beats:value)
        case "touch": d.touch = value > 0
        case "jog": audio.jog(deck:index,delta:value,scratch:d.touch)
        default: if command.hasPrefix("hotcue"), let slot = Int(command.dropFirst(6)), value > 0 { triggerHotcue(index,slot:slot-1) }
        }
    }
    func persistPreparation(_ deck: Int) { let d = decks[deck]; guard let key = loadedPaths[deck] else { return }; preparation[key] = SavedPreparation(cue: d.cue, hotcues: d.hotcues, bpm: d.bpm); save() }
    func save() { persistence.schedule(tracks:tracks,preparation:preparation) }
    func shutdown() { stopAll(); finishRecording(); for d in decks { persistPreparation(d.id) }; save(); persistence.flush(); midi.flushMappingChanges() }

}

func formatTime(_ seconds: Double) -> String { guard seconds.isFinite else { return "0:00" }; let s = max(0,Int(seconds)); return String(format:"%d:%02d",s/60,s%60) }
