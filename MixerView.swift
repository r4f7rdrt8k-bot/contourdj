import SwiftUI

struct ChannelStrip: View {
    @ObservedObject var deck: DeckState
    @ObservedObject var model: PerformanceModel
    var body: some View {
        VStack(spacing:10) {
            Text(deck.letter).font(.system(size:12,weight:.bold)).foregroundStyle(Color.primary)
            eq("High",value:$deck.high)
            eq("Mid",value:$deck.mid)
            eq("Low",value:$deck.low)
            VStack(spacing:3) {
                Text("Filter").font(.system(size:10)).foregroundStyle(.secondary)
                Slider(value:$deck.filter,in:-1...1).tint(deck.color).onChange(of:deck.filter) { model.audio.setFilter(deck:deck.id,value:deck.filter) }.accessibilityLabel("Deck \(deck.letter) filter")
                Text(abs(deck.filter) < 0.03 ? "Off" : (deck.filter < 0 ? "Low-pass" : "High-pass")).font(.system(size:10)).foregroundStyle(.secondary)
            }
            Divider()
            Slider(value:Binding(get:{deck.volume},set:{model.setVolume(deck.id,$0)}),in:0...1).rotationEffect(.degrees(-90)).frame(width:112,height:40).frame(width:40,height:112).tint(deck.color).accessibilityLabel("Deck \(deck.letter) channel volume").accessibilityValue("\(Int(deck.volume*100)) percent")
            Text(String(format:"%.0f%%",deck.volume*100)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
        }.frame(minWidth:56,maxWidth:90)
    }
    func eq(_ title: String,value:Binding<Double>) -> some View {
        VStack(spacing:2) {
            HStack { Text(title);Spacer(minLength:0);Text(String(format:"%+.0f",value.wrappedValue)).monospacedDigit() }.font(.system(size:10)).foregroundStyle(.secondary)
            Slider(value:value,in:-24...12).tint(deck.color).onChange(of:value.wrappedValue) { model.updateEQ(deck.id) }.accessibilityLabel("Deck \(deck.letter) \(title) EQ in decibels")
        }
    }
}

struct MixerPanel: View {
    @ObservedObject var model: PerformanceModel
    var channels: [DeckState]
    var body: some View {
        VStack(spacing:14) {
            Text("MIXER").font(.system(size:10,weight:.semibold)).tracking(1.5).foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:16) { ForEach(channels) { ChannelStrip(deck:$0,model:model) } }
            Divider()
            CrossfaderControl(model:model,mix:model.mix,width:nil)
            Button("Center") { model.setCrossfader(0.5) }.buttonStyle(.borderless).font(.caption).help("Center the crossfader")
        }
        .padding(.horizontal,14).padding(.vertical,18)
        .background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:14))
        .frame(width:channels.count > 2 ? 300 : 190)
    }
}

struct MasterMeter: View {
    var peak: Float
    var body: some View {
        HStack(spacing:2) {
            ForEach(0..<18,id:\.self) { index in
                RoundedRectangle(cornerRadius:1).fill(Float(index)/18 < min(1,peak) ? (index > 15 ? Color.orange : Color.green) : Color.primary.opacity(0.08)).frame(width:3,height:CGFloat(5+index/3))
            }
        }.frame(height:14).accessibilityLabel("Master output level").accessibilityValue("\(Int(min(1,peak)*100)) percent")
    }
}

struct CrossfaderControl: View {
    let model:PerformanceModel
    @ObservedObject var mix:MixControlState
    var width:CGFloat?
    var body:some View {
        HStack(spacing:5) {
            Text("A/C").font(.system(size:10)).foregroundStyle(.secondary)
            Slider(value:Binding(get:{mix.crossfader},set:{model.setCrossfader($0)}),in:0...1).frame(width:width).accessibilityLabel("Crossfader, A and C to B and D")
            Text("B/D").font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
}
struct LiveMasterMeter:View {
    @ObservedObject var meter:MasterMeterState
    var body:some View {MasterMeter(peak:meter.peak)}
}
struct GlobalMixControls:View {
    let model:PerformanceModel
    @ObservedObject var mix:MixControlState
    let meter:MasterMeterState
    var body:some View {
        HStack(spacing:12) {
            CrossfaderControl(model:model,mix:mix,width:110)
            HStack(spacing:10) {
                LiveMasterMeter(meter:meter)
                Slider(value:Binding(get:{mix.masterVolume},set:{model.setMaster($0)}),in:0...1).frame(width:90).accessibilityLabel("Master output volume")
                Text("MASTER").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}
