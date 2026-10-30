
extension DJAudioEngine {
    nonisolated fileprivate static func dumpDemo(_ variant:Int) throws -> DecodedTrack { try makeDemo(variant:variant) }
    fileprivate func forcePoll() { poll() }
}
@main struct ExtraBench {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--nudge") {
            let engine=DJAudioEngine()
            let began=DispatchTime.now().uptimeNanoseconds
            for i in 0..<10000 { engine.jog(deck:0,delta:i&1 == 0 ? 1:-1,scratch:false) }
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000
            try?await Task.sleep(nanoseconds:220_000_000)
            engine.forcePoll()
            var result:[String:Any] = ["events":10000,"enqueueMS":elapsed,"outputStarted":engine.isRunning]
            #if OPTIMIZED
            result["wrapperMetrics"]=engine.performanceMetrics
            #endif
            engine.stop()
            print(String(decoding:try!JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        } else {
            for variant in 0..<2 {
                let decoded=try!DJAudioEngine.dumpDemo(variant)
                let data=decoded.samples.withUnsafeBufferPointer { Data(buffer:$0) }
                try!data.write(to:URL(fileURLWithPath:CommandLine.arguments[1] + "-demo" + String(variant) + ".f32"))
            }
        }
    }
}
