import SwiftUI
import UniformTypeIdentifiers

/// One bounded geometry cache per visible waveform, reused while the playhead moves.
private final class WaveformGeometryCache {
    private let lock = NSLock()
    private var revision: UInt64 = .max
    private var size = CGSize.zero
    private var cached = Path()
    func path(samples:[Float],revision:UInt64,size:CGSize) -> Path {
        lock.lock();defer {lock.unlock()}
        if self.revision == revision && self.size == size { return cached }
        var wave = Path()
        let center = size.height/2
        let count = min(max(0,Int(size.width/2.5)),samples.count)
        for i in 0..<count {
            let index = min(samples.count-1,i*samples.count/max(1,count))
            let h = max(1,CGFloat(samples[index])*center*0.92)
            wave.addRoundedRect(in:CGRect(x:CGFloat(i)*size.width/CGFloat(count),y:center-h,width:max(1,size.width/CGFloat(count)-1),height:h*2),cornerSize:CGSize(width:0.7,height:0.7))
        }
        self.revision = revision;self.size = size;cached = wave
        return wave
    }
}

private struct WaveformInk: View, Equatable {
    let samples:[Float]
    let revision:UInt64
    let color:Color
    @State private var geometry = WaveformGeometryCache()
    static func == (a:Self,b:Self) -> Bool { a.revision == b.revision && a.color == b.color }
    var body:some View {
        Canvas { context,size in
            var middle = Path();middle.move(to:CGPoint(x:0,y:size.height/2));middle.addLine(to:CGPoint(x:size.width,y:size.height/2))
            context.stroke(middle,with:.color(.secondary.opacity(0.15)),lineWidth:1)
            context.fill(geometry.path(samples:samples,revision:revision,size:size),with:.color(color))
        }
    }
}

struct WaveformView: View {
    @ObservedObject var deck: DeckState
    @ObservedObject private var clock: DeckClock
    var seek: (Double) -> Void
    init(deck:DeckState,seek:@escaping(Double)->Void) { self.deck = deck;self.clock = deck.clock;self.seek = seek }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                WaveformInk(samples:deck.waveform,revision:deck.waveformRevision,color:deck.color).equatable()
                Canvas { context,size in
                    if deck.looping, deck.duration > 0 {
                        let x = deck.loopStart/deck.duration*size.width,end = deck.loopEnd/deck.duration*size.width
                        context.fill(Path(CGRect(x:x,y:0,width:max(2,end-x),height:size.height)),with:.color(deck.color.opacity(0.15)))
                    }
                    for (slot,cue) in deck.hotcues.enumerated() {
                        guard let cue,deck.duration > 0 else {continue}
                        let x = cue/deck.duration*size.width
                        var p = Path();p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height))
                        context.stroke(p,with:.color(deck.color.opacity(0.4)),lineWidth:1)
                        context.draw(Text("\(slot+1)").font(.system(size:10,weight:.bold)).foregroundStyle(deck.color),at:CGPoint(x:min(size.width-5,max(6,x+5)),y:8))
                    }
                    let x = deck.duration > 0 ? min(size.width,max(0,clock.position/deck.duration*size.width)) : 0
                    var playhead=Path();playhead.move(to:CGPoint(x:x,y:0));playhead.addLine(to:CGPoint(x:x,y:size.height))
                    context.stroke(playhead,with:.color(.primary),lineWidth:1.5)
                    context.fill(Path(CGRect(x:0,y:size.height-2,width:x,height:2)),with:.color(deck.color))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in seek(value.location.x/max(1,geo.size.width)*deck.duration) })
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Deck \(deck.letter) waveform")
            .accessibilityValue("\(formatTime(clock.position)) of \(formatTime(deck.duration))")
            .accessibilityAdjustableAction { direction in seek(clock.position + (direction == .increment ? 1 : -1)) }
        }
        .frame(height:90)
        .background(deck.color.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
        .help("Click or drag to seek. Numbered markers are your saved Hotcues.")
    }
}

private struct DeckTimeReadout: View {
    @ObservedObject var deck:DeckState
    @ObservedObject private var clock:DeckClock
    init(deck:DeckState) {self.deck=deck;self.clock=deck.clock}
    var body:some View {
        HStack {
            Text(formatTime(clock.position)).font(.system(size:19,weight:.medium,design:.monospaced))
            Spacer()
            if deck.looping { Label("\(loopText(deck.loopBeats)) Beat Loop",systemImage:"repeat").font(.caption).foregroundStyle(deck.color) }
            Text("−"+formatTime(max(0,deck.duration-clock.position))).font(.system(size:13,design:.monospaced)).foregroundStyle(.secondary)
        }
    }
}

struct DeckPanel: View {
    @ObservedObject var deck: DeckState
    @ObservedObject var model: PerformanceModel
    @State private var bpmText = ""
    @State private var editBPM = false
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:10) {
                Text(deck.letter).font(.system(size:20,weight:.semibold,design:.rounded)).foregroundStyle(Color.primary)
                    .frame(width:36,height:36).background(deck.color.opacity(0.12),in:RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:4) {
                    Text(deck.title).font(.system(size:17,weight:.semibold)).lineLimit(1).help(deck.title)
                    Text(deck.loading ? "Preparing audio…" : deck.artist).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength:6)
                Button { bpmText = String(format:"%.2f",deck.bpm); editBPM = true } label: {
                    VStack(alignment:.trailing,spacing:2) {
                        Text(deck.loaded ? String(format:"%.1f",deck.effectiveBPM) : "—").font(.system(size:26,weight:.medium,design:.rounded)).monospacedDigit()
                        Text("BPM · \(deck.playing ? "Playing" : "Paused")").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help("Edit the estimated source BPM").accessibilityLabel("Deck \(deck.letter) tempo, \(String(format:"%.1f",deck.effectiveBPM)) BPM. Edit source BPM")
                .popover(isPresented:$editBPM) {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Source Tempo").font(.headline)
                        Text("BPM is estimated. Adjust it here for accurate loops and Beatjump.").font(.caption).foregroundStyle(.secondary).frame(width:245)
                        TextField("BPM",text:$bpmText).onSubmit { if let bpm = Double(bpmText) { model.changeBPM(deck.id,bpm) }; editBPM = false }
                        Button("Apply") { if let bpm = Double(bpmText) { model.changeBPM(deck.id,bpm) }; editBPM = false }.keyboardShortcut(.defaultAction)
                    }.padding(20)
                }
            }
            WaveformView(deck:deck) { model.seek(deck.id,to:$0) }
            DeckTimeReadout(deck:deck)
            HStack(spacing:8) {
                Button { model.togglePlay(deck.id) } label: { Label(deck.playing ? "Pause" : "Play",systemImage:deck.playing ? "pause.fill" : "play.fill").frame(minWidth:64) }
                    .buttonStyle(.borderedProminent).tint(.accentColor).controlSize(.large).disabled(!deck.loaded || deck.loading).help("Play or pause Deck \(deck.letter) · ⌘\(deck.id+1)")
                Button("Cue") { model.cue(deck.id) }.controlSize(.large).help("While paused, set a cue. While playing, stop and return to the cue.")
                Spacer(minLength:2)
                Button { model.matchTempo(deck.id) } label: { Label("Match",systemImage:"arrow.left.arrow.right") }.help("Match the other deck’s tempo. This does not align beat phase or preserve pitch.").disabled(!deck.loaded)
                Menu {
                    Button("Load Selected Track") { model.loadSelected(deck.id) }
                    Button("Stop and Return to Start") { model.stop(deck.id) }
                    Toggle("Reverse",isOn:Binding(get:{deck.reversed},set:{_ in model.toggleReverse(deck.id)}))
                    Button("Reset Tempo") { model.setRate(deck.id,1) }
                    Button("Reset EQ and Filter") { deck.low = 0;deck.mid = 0;deck.high = 0;deck.filter = 0;model.updateEQ(deck.id);model.audio.setFilter(deck:deck.id,value:0) }
                } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:26).help("Deck \(deck.letter) actions").accessibilityLabel("Deck \(deck.letter) actions")
            }
            HStack(spacing:5) {
                ForEach(0..<8,id:\.self) { slot in
                    Button { model.triggerHotcue(deck.id,slot:slot) } label: {
                        Text("\(slot+1)").font(.system(size:12,weight:.semibold,design:.rounded)).frame(maxWidth:.infinity,minHeight:26)
                            .foregroundStyle(deck.hotcues[slot] == nil ? Color.secondary : Color.primary)
                            .background(deck.hotcues[slot] == nil ? Color.primary.opacity(0.035) : deck.color.opacity(0.12),in:RoundedRectangle(cornerRadius:5))
                    }.buttonStyle(.plain).disabled(!deck.loaded)
                    .accessibilityLabel("Deck \(deck.letter) Hotcue \(slot+1), \(deck.hotcues[slot].map { formatTime($0) } ?? "empty, click to set")")
                    .help(deck.hotcues[slot].map { "Recall \(formatTime($0)). Right-click to clear." } ?? "Set Hotcue \(slot+1) at the current position")
                    .contextMenu { Button("Clear Hotcue \(slot+1)") { model.triggerHotcue(deck.id,slot:slot,clear:true) }.disabled(deck.hotcues[slot] == nil) }
                }
            }
            HStack(spacing:6) {
                Button { model.beatjump(deck.id,beats:-deck.loopBeats) } label: { Image(systemName:"backward.end") }.help("Jump backward \(loopText(deck.loopBeats)) beats").accessibilityLabel("Jump backward \(loopText(deck.loopBeats)) beats")
                Button { model.toggleLoop(deck.id) } label: { Image(systemName:"repeat") }.tint(deck.looping ? deck.color : nil).help("Toggle a loop at the current beat").accessibilityLabel(deck.looping ? "Exit loop" : "Start loop")
                Picker("Loop Beats",selection:Binding(get:{deck.loopBeats},set:{model.changeLoopLength(deck.id,$0)})) {
                    ForEach([0.5,1,2,4,8,16,32],id:\.self) { Text(loopText($0)).tag($0) }
                }.labelsHidden().frame(maxWidth:90).help("Loop and Beatjump length in beats")
                Button { model.beatjump(deck.id,beats:deck.loopBeats) } label: { Image(systemName:"forward.end") }.help("Jump forward \(loopText(deck.loopBeats)) beats").accessibilityLabel("Jump forward \(loopText(deck.loopBeats)) beats")
                Spacer(minLength:0)
                if deck.reversed { Image(systemName:"backward.fill").foregroundStyle(deck.color).help("Reverse is on") }
                Text(String(format:"%+.1f%%",(deck.rate-1)*100)).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).frame(width:56,alignment:.trailing)
            }.controlSize(.small).disabled(!deck.loaded)
            HStack(spacing:8) {
                Text("Tempo").font(.caption).foregroundStyle(.secondary).frame(width:42,alignment:.leading)
                Slider(value:Binding(get:{deck.rate},set:{model.setRate(deck.id,$0)}),in:0.5...1.5).tint(deck.color).help("Playback speed ±50%. Speed also changes pitch.").accessibilityLabel("Deck \(deck.letter) tempo rate")
                Button { model.setRate(deck.id,1) } label: { Image(systemName:"arrow.counterclockwise") }.buttonStyle(.borderless).help("Reset tempo").accessibilityLabel("Reset Deck \(deck.letter) tempo")
            }
            Divider()
            HStack(spacing:8) {
                Text("FX").font(.caption).foregroundStyle(.secondary)
                Picker("Effect",selection:$deck.effect) { Text("Off").tag(0);Text("Echo").tag(1);Text("Space").tag(2);Text("Flanger").tag(3) }.labelsHidden().frame(maxWidth:105).onChange(of:deck.effect) { model.updateEffect(deck.id) }
                Slider(value:$deck.effectMix,in:0...0.75).onChange(of:deck.effectMix) { model.updateEffect(deck.id) }.tint(deck.color).disabled(deck.effect == 0).accessibilityLabel("Deck \(deck.letter) effect mix")
                Text(String(format:"%.0f%%",deck.effectMix*100)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).frame(width:30)
            }
        }
        .padding(18)
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).stroke(model.activeDeck == deck.id ? deck.color.opacity(0.5) : Color.primary.opacity(0.08),lineWidth:1))
        .onTapGesture { model.activeDeck = deck.id }
        .dropDestination(for:URL.self) { urls,_ in model.addFiles(urls,loadInto:deck.id);return true }
        .accessibilityElement(children:.contain).accessibilityLabel("Deck \(deck.letter)")
    }
}

func loopText(_ value: Double) -> String { value < 1 ? "½" : String(Int(value)) }
