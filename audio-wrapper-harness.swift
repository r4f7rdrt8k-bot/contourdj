
extension DJAudioEngine {
    nonisolated fileprivate static func profileDecode(url:URL) throws -> DecodedTrack { try decode(url:url) }
    nonisolated fileprivate static func profileDemo(_ variant:Int) throws -> DecodedTrack { try makeDemo(variant:variant) }
}
@MainActor private enum ProfileLoad {
    static func load(owner:AudioCoreOwner,url:URL?,demo:Int?,deck:Int) async throws -> TrackAnalysis {
        let decoded=try await Task.detached(priority:.userInitiated) {
            if let url { return try DJAudioEngine.profileDecode(url:url) }
            return try DJAudioEngine.profileDemo(demo ?? 0)
        }.value
        #if OPTIMIZED
        let success=await owner.install(decoded,deck:deck).success
        #else
        let success=decoded.samples.withUnsafeBufferPointer { cdj_load(owner.pointer,Int32(deck),$0.baseAddress,UInt64($0.count/2),decoded.analysis.sampleRate) }
        #endif
        guard success else {throw AudioFailure.message("Core load failed")}
        return decoded.analysis
    }
}

@MainActor private final class Heartbeat {
    var last = DispatchTime.now().uptimeNanoseconds
    var maximumGapMS = 0.0
    var samples = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    func start() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.maximumGapMS = max(self.maximumGapMS, Double(now-self.last)/1_000_000)
            self.last=now;self.samples += 1
        }}
        timer.resume()
    }
    func reset() { last=DispatchTime.now().uptimeNanoseconds;maximumGapMS=0;samples=0 }
}
@main struct WrapperBench {
    @MainActor static func main() async {
        let owner=try!AudioCoreOwner(), beat=Heartbeat();beat.start()
        var cases:[[String:Any]]=[]
        let inputs=[("fixture40", "/Users/yassinghobara/Desktop/Traktor-Pro-4-Analysis/runtime/fixtures/rea_synth_120bpm_40s.wav"),("eightMinute", "/private/tmp/contour-audio-wrapper-profile/eight-minute.wav")]
        for (label,path) in inputs {
            for run in 0..<3 {
                try? await Task.sleep(nanoseconds:30_000_000);beat.reset()
                let start=DispatchTime.now().uptimeNanoseconds
                do {
                    let analysis=try await ProfileLoad.load(owner:owner,url:URL(fileURLWithPath:path),demo:nil,deck:0)
                    let durationMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                    try? await Task.sleep(nanoseconds:15_000_000)
                    cases.append(["case":label,"run":run,"loadMS":durationMS,"mainMaxGapMS":beat.maximumGapMS,"heartbeatSamples":beat.samples,"duration":analysis.duration,"bins":analysis.waveform.count])
                } catch {cases.append(["case":label,"error":error.localizedDescription])}
            }
        }
        for run in 0..<3 {
            try? await Task.sleep(nanoseconds:30_000_000);beat.reset()
            let start=DispatchTime.now().uptimeNanoseconds
            do {
                let analysis=try await ProfileLoad.load(owner:owner,url:nil,demo:run&1,deck:1)
                let durationMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                try? await Task.sleep(nanoseconds:15_000_000)
                cases.append(["case":"demo64","run":run,"loadMS":durationMS,"mainMaxGapMS":beat.maximumGapMS,"heartbeatSamples":beat.samples,"duration":analysis.duration])
            } catch {cases.append(["case":"demo64","error":error.localizedDescription])}
        }
        beat.timer.cancel()
        let data=try!JSONSerialization.data(withJSONObject:["cases":cases,"optimization":"-O","engineOutputStarted":false],options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
    }
}
