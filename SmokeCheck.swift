import Foundation
import AVFoundation
import AppKit

@MainActor enum SmokeCheck {
    static var ran = false
    static func run(_ model: PerformanceModel) async {
        guard !ran else { return };ran = true
        let directory = model.dataDirectory
        let recording = directory.appendingPathComponent("smoke-mix.wav")
        var results: [String:Any] = ["started":Date().description,"mode":"Live AVAudioEngine with synthetic demo audio; no personal media","demoDecksLoaded":model.decks[0].loaded && model.decks[1].loaded]
        do {
            guard model.decks[0].loaded && model.decks[1].loaded else { throw NSError(domain:"SmokeCheck",code:1,userInfo:[NSLocalizedDescriptionKey:"Demo audio did not load"]) }
            model.setMaster(0.15)
            model.midi.simulate(action:"deck0.play",value:1)
            model.midi.simulate(action:"deck1.play",value:1)
            model.beginRecording(recording)
            try await Task.sleep(nanoseconds:1_200_000_000)
            model.tick();let p1=model.decks[0].position
            results["playbackAdvanced"] = p1 > 0.2
            model.midi.simulate(action:"mixer.crossfader",value:0)
            results["midiActionCrossfader"] = model.crossfader == 0
            model.triggerHotcue(0,slot:0,clear:true)
            model.triggerHotcue(0,slot:0)
            model.beatjump(0,beats:4)
            model.triggerHotcue(0,slot:0)
            results["hotcueRecalls"] = abs(model.decks[0].position - p1) < 0.1
            model.toggleLoop(0)
            results["loopEnabled"] = model.decks[0].looping
            model.setRate(1,1.08);model.decks[1].low = -12;model.updateEQ(1)
            model.decks[1].effect = 1;model.updateEffect(1)
            model.patternEnabled = true;model.updatePattern()
            try await Task.sleep(nanoseconds:1_200_000_000)
            model.setCrossfader(1)
            try await Task.sleep(nanoseconds:600_000_000)
            model.stopAll();model.finishRecording()
            try await Task.sleep(nanoseconds:400_000_000)
            let file = try AVAudioFile(forReading:recording)
            let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
            try file.read(into:buffer)
            var peak:Float = 0
            if let ptr = buffer.floatChannelData { for c in 0..<Int(buffer.format.channelCount) { for n in 0..<Int(buffer.frameLength) { peak = max(peak,abs(ptr[c][n])) } } }
            results["recordingFrames"] = Int(file.length)
            results["recordingSampleRate"] = file.processingFormat.sampleRate
            results["recordingPeak"] = peak
            results["recordingNonzero"] = peak > 0.0001 && file.length > 20_000
            results["preparationSaved"] = FileManager.default.fileExists(atPath:directory.appendingPathComponent("preparation.json").path)
            if let corpus = ProcessInfo.processInfo.environment["CONTOUR_TEST_CORPUS"] {
                let root = URL(fileURLWithPath:corpus)
                let cases = ["rea_synth_120bpm_40s.wav","codec_variants/rea_synth_120bpm_40s.aiff","codec_variants/rea_synth_120bpm_40s.mp3","codec_variants/rea_synth_120bpm_40s.flac","codec_variants/rea_synth_120bpm_40s_aac.m4a","codec_variants/rea_synth_120bpm_40s_alac.m4a","codec_variants/rea_synth_120bpm_40s.ogg"]
                var formats:[[String:Any]] = []
                for name in cases {
                    do { let analysis = try await model.audio.load(url:root.appendingPathComponent(name),deck:2);formats.append(["file":name,"loaded":true,"duration":analysis.duration,"estimatedBPM":analysis.bpm,"waveformNonzero":analysis.waveform.contains { $0 > 0 }]) }
                    catch { formats.append(["file":name,"loaded":false,"error":error.localizedDescription]) }
                }
                results["codecLoadChecks"] = formats
                results["allCodecLoadChecksPassed"] = formats.count == 7 && formats.allSatisfy { $0["loaded"] as? Bool == true && $0["waveformNonzero"] as? Bool == true }
            }
            results["engineError"] = model.audio.errorMessage ?? model.error ?? NSNull()
            results["passed"] = (results["playbackAdvanced"] as? Bool == true) && (results["midiActionCrossfader"] as? Bool == true) && (results["recordingNonzero"] as? Bool == true) && (results["hotcueRecalls"] as? Bool == true) && model.audio.errorMessage == nil && model.error == nil && (results["allCodecLoadChecksPassed"] as? Bool ?? true)
        } catch { results["passed"] = false;results["error"] = error.localizedDescription }
        results["finished"] = Date().description
        if let data = try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:directory.appendingPathComponent("smoke-test.json"),options:.atomic) }
        model.shutdown()
        NSApp.terminate(nil)
    }
}
