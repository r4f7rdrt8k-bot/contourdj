// Conversion callbacks run synchronously inside the single serialized decode job.
@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import CDJCore

struct TrackAnalysis: Sendable {
    let title: String
    let artist: String
    let duration: Double
    /// Estimated from an onset envelope for files; known synthesis tempo for demos.
    let bpm: Double
    let waveform: [Float]
    let sampleRate: Double
}

private enum AudioFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// The source node holds this owner throughout callback lifetime. Engine.stop()
/// quiesces output before the owning DJAudioEngine releases it.
private final class AudioCoreOwner: @unchecked Sendable {
    let pointer: OpaquePointer
    private let maintenance = DispatchQueue(label: "audio.contour.pcm", qos: .userInitiated)
    init() throws {
        guard let p = cdj_create(48_000) else { throw AudioFailure.message("Could not allocate the audio mixer.") }
        pointer = p
    }
    /// PCM allocation/copy and retired-buffer destruction never block the UI.
    /// Retaining self also keeps the core alive through an in-flight install.
    func install(_ decoded: DecodedTrack, deck: Int) async -> (success: Bool, milliseconds: Double) {
        await withCheckedContinuation { continuation in
            maintenance.async { [self] in
                let began = DispatchTime.now().uptimeNanoseconds
                let success = decoded.samples.withUnsafeBufferPointer {
                    cdj_load(pointer, Int32(deck), $0.baseAddress, UInt64($0.count / 2), decoded.analysis.sampleRate)
                }
                continuation.resume(returning: (success, Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000))
            }
        }
    }
    func reclaim() { maintenance.async { [self] in cdj_reclaim(pointer) } }
    deinit { cdj_destroy(pointer) }
}

private struct DecodedTrack: Sendable {
    let samples: [Float]
    let analysis: TrackAnalysis
}

private struct PreparedTrack: Sendable {
    let analysis: TrackAnalysis
    let decodeMilliseconds: Double
    let installMilliseconds: Double
}

/// Permit covers decode AND installation, so multiple rapid load requests do
/// not accumulate full PCM results while the main actor is handling another.
private actor AudioDecodeGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Fixed-capacity recording ring lives in C++. This serial queue is its only
/// consumer. No audio-thread dispatch, file I/O, Swift allocation or unbounded
/// enqueue occurs. A ~10.9s writer stall drops frames and is reported explicitly.
private final class AudioRecordingWriter: @unchecked Sendable {
    private let core: AudioCoreOwner
    private let queue = DispatchQueue(label: "audio.contour.recording", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var scratch = [Float](repeating: 0, count: 32_768)
    private let errorLock = NSLock()
    private var storedError: String?
    var error: String? { errorLock.lock(); defer { errorLock.unlock() }; return storedError }
    private func report(_ message: String) { errorLock.lock(); storedError = message; errorLock.unlock() }

    init(core: AudioCoreOwner) { self.core = core; queue.setSpecific(key: queueKey, value: true) }

    func start(url: URL) throws {
        try queue.sync {
            guard file == nil else { throw AudioFailure.message("A recording is already open.") }
            errorLock.lock(); storedError = nil; errorLock.unlock()
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let opened = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw AudioFailure.message("Could not allocate the recording buffer.")
            }
            guard cdj_record_begin(core.pointer) else { throw AudioFailure.message("Recorder is already active.") }
            file = opened; buffer = pcm
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(5))
            source.setEventHandler { [weak self] in self?.drain() }
            timer = source; source.resume()
        }
    }

    private func drain() {
        guard let file, let buffer, let channels = buffer.floatChannelData else { return }
        while true {
            let count = scratch.withUnsafeMutableBufferPointer { cdj_record_drain(core.pointer, $0.baseAddress, 16_384) }
            if count == 0 { return }
            buffer.frameLength = count
            for i in 0..<Int(count) { channels[0][i] = scratch[i * 2]; channels[1][i] = scratch[i * 2 + 1] }
            do { try file.write(from: buffer) }
            catch {
                report("Recording stopped: \(error.localizedDescription)")
                cdj_record_end(core.pointer)
                return
            }
        }
    }

    /// Closing AVAudioFile on this queue finalizes its container before return.
    func stop() -> String? {
        cdj_record_end(core.pointer)
        let finish = {
            [self] in
            timer?.cancel(); timer = nil
            drain()
            file = nil; buffer = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() }
        else { queue.sync(execute: finish) }
        let dropped = cdj_record_dropped(core.pointer)
        if dropped > 0 { report("Recording writer fell behind; \(dropped) audio frames were dropped.") }
        return error
    }
    deinit { _ = stop() }
}

@MainActor
final class DJAudioEngine: ObservableObject {
    @Published var errorMessage: String?
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var recordingURL: URL?
    @Published var masterPeak: Float = 0
    /// One UI snapshot clock, shared with PerformanceModel. Called on main.
    var onPoll: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var core: AudioCoreOwner?
    private var recorder: AudioRecordingWriter?
    private var meterTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var pollIsActive = false
    private var nextReclaim: UInt64 = 0
    private var patternEnabled = false
    private var interactionUntil: UInt64 = 0
    private var pollCount: UInt64 = 0
    private var jogCount: UInt64 = 0
    private var nudgeRestoreCount: UInt64 = 0
    private var lastDecodeMilliseconds: Double = 0
    private var lastInstallMilliseconds: Double = 0
    private var loadVersions = [UInt64](repeating: 0, count: 4)
    private var rates = [Double](repeating: 1, count: 4)
    private var nudgeDeadlines = [UInt64](repeating: 0, count: 4)
    private static let decodeGate = AudioDecodeGate()

    init() {
        do {
            let owner = try AudioCoreOwner()
            core = owner; recorder = AudioRecordingWriter(core: owner)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let node = AVAudioSourceNode(format: format) { _, _, count, list -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                guard buffers.count >= 2,
                      let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                    for b in buffers { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
                    return noErr
                }
                cdj_render(owner.pointer, l, r, count)
                return noErr
            }
            source = node; engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            configurePolling(active: false)
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Synchronous final drain/AVAudioFile close before app exit;
                // a detached/asynchronous task could be abandoned on quit.
                MainActor.assumeIsolated { self?.stop() }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    deinit {
        meterTimer?.invalidate()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        engine.stop()
        _ = recorder?.stop()
    }

    private func configurePolling(active: Bool) {
        guard meterTimer == nil || pollIsActive != active else { return }
        meterTimer?.invalidate(); pollIsActive = active
        let timer = Timer(timeInterval: active ? 1.0 / 30 : 0.25, repeats: true) { [weak self] _ in
            // Registered only on the main RunLoop: no per-tick Task allocation.
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = active ? 0.003 : 0.025
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Timings exclude the wait for the bounded decode gate. They describe the
    /// latest completed load; output-device latency needs separate measurement.
    var performanceMetrics: [String: Double] {
        ["lastDecodeMS": lastDecodeMilliseconds, "lastInstallMS": lastInstallMilliseconds,
         "pollCount": Double(pollCount), "pollHz": pollIsActive ? 30 : 4,
         "jogEvents": Double(jogCount), "nudgeRestores": Double(nudgeRestoreCount)]
    }

    private func poll() {
        guard let core else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        pollCount &+= 1
        let peak = cdj_peak(core.pointer)
        if masterPeak != peak { masterPeak = peak }
        for deck in 0..<4 where nudgeDeadlines[deck] > 0 && nudgeDeadlines[deck] <= now {
            nudgeDeadlines[deck] = 0
            cdj_rate(core.pointer, Int32(deck), rates[deck]); nudgeRestoreCount &+= 1
        }
        if now >= nextReclaim { nextReclaim = now &+ 1_000_000_000; core.reclaim() }
        if isRecording, let failure = recorder?.error {
            stopRecording(); errorMessage = failure
        }
        if isRunning && !engine.isRunning { isRunning = false }
        onPoll?()
        let active = isRecording || patternEnabled || now < interactionUntil || nudgeDeadlines.contains(where: { $0 > 0 }) ||
            (0..<4).contains(where: { cdj_is_playing(core.pointer, Int32($0)) })
        configurePolling(active: active)
    }

    func start() throws {
        guard core != nil else { throw AudioFailure.message(errorMessage ?? "Audio mixer unavailable.") }
        if engine.isRunning { isRunning = true; return }
        do { engine.prepare(); try engine.start(); isRunning = true }
        catch { isRunning = false; errorMessage = error.localizedDescription; throw error }
    }

    func stop() {
        stopRecording(); engine.stop(); isRunning = false
        if masterPeak != 0 { masterPeak = 0 }
        interactionUntil = 0
        nudgeDeadlines = Array(repeating: 0, count: 4)
        if let core { for deck in 0..<4 { cdj_rate(core.pointer, Int32(deck), rates[deck]) } }
        configurePolling(active: false)
    }

    private func valid(_ deck: Int) -> Bool { (0..<4).contains(deck) }

    func load(url: URL, deck: Int) async throws -> TrackAnalysis {
        try await prepareTrack(deck: deck) { try Self.decode(url: url) }
    }

    func loadDemo(deck: Int, variant: Int? = nil) async throws -> TrackAnalysis {
        let selection = (variant ?? deck) & 1
        return try await prepareTrack(deck: deck) { try Self.makeDemo(variant: selection) }
    }

    private func loadIsCurrent(deck: Int, version: UInt64) -> Bool { loadVersions[deck] == version }

    private func prepareTrack(deck: Int, decode: @escaping @Sendable () throws -> DecodedTrack) async throws -> TrackAnalysis {
        guard valid(deck) else { throw AudioFailure.message("Deck index must be 0 through 3.") }
        guard let owner = core else { throw AudioFailure.message("Audio mixer unavailable.") }
        loadVersions[deck] &+= 1; let version = loadVersions[deck]
        await Self.decodeGate.acquire()
        do {
            guard version == loadVersions[deck] else { throw CancellationError() }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { [weak self, owner] in
                let began = DispatchTime.now().uptimeNanoseconds
                let decoded = try decode()
                let decodeMS = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                try Task.checkCancellation()
                guard await self?.loadIsCurrent(deck: deck, version: version) == true else { throw CancellationError() }
                let installed = await owner.install(decoded, deck: deck)
                guard installed.success else { throw AudioFailure.message("Track could not be loaded within the mixer's 1 GiB PCM budget. Try a shorter track.") }
                try Task.checkCancellation()
                // Only the small analysis escapes this worker. The temporary
                // decoded PCM also deallocates here, away from the main actor.
                return PreparedTrack(analysis: decoded.analysis, decodeMilliseconds: decodeMS, installMilliseconds: installed.milliseconds)
            }
            let prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard version == loadVersions[deck] else { throw CancellationError() }
            try Task.checkCancellation()
            nudgeDeadlines[deck] = 0; rates[deck] = 1; cdj_rate(owner.pointer, Int32(deck), 1)
            lastDecodeMilliseconds = prepared.decodeMilliseconds; lastInstallMilliseconds = prepared.installMilliseconds
            await Self.decodeGate.release()
            return prepared.analysis
        } catch { await Self.decodeGate.release(); throw error }
    }

    func play(deck: Int) { if valid(deck), let core { cdj_play(core.pointer, Int32(deck), true); configurePolling(active: true) } }
    func pause(deck: Int) { if valid(deck), let core { cdj_play(core.pointer, Int32(deck), false) } }
    func seek(deck: Int, seconds: Double) { if valid(deck), let core { cdj_seek(core.pointer, Int32(deck), seconds) } }
    func position(deck: Int) -> Double { guard valid(deck), let core else { return 0 }; return cdj_position(core.pointer, Int32(deck)) }
    func setRate(deck: Int, rate: Double) {
        guard valid(deck), let core else { return }
        nudgeDeadlines[deck] = 0; rates[deck] = rate.isFinite ? min(4, max(0.25, rate)) : 1
        cdj_rate(core.pointer, Int32(deck), rates[deck])
    }
    func setVolume(deck: Int, volume: Double) { if valid(deck), let core { cdj_volume(core.pointer, Int32(deck), volume) } }
    func setEQ(deck: Int, low: Double, mid: Double, high: Double) { if valid(deck), let core { cdj_eq(core.pointer, Int32(deck), low, mid, high) } }
    func setFilter(deck: Int, value: Double) { if valid(deck), let core { cdj_filter(core.pointer, Int32(deck), value) } }
    func setEffect(deck: Int, kind: Int, mix: Double) { if valid(deck), let core { cdj_effect(core.pointer, Int32(deck), Int32(kind), mix) } }
    func setCrossfader(_ value: Double) { if let core { cdj_crossfader(core.pointer, value) } }
    func setMasterVolume(_ value: Double) { if let core { cdj_master(core.pointer, value) } }
    func setLoop(deck: Int, start: Double, end: Double, enabled: Bool) { if valid(deck), let core { cdj_loop(core.pointer, Int32(deck), start, end, enabled) } }
    func setReverse(deck: Int, enabled: Bool) { if valid(deck), let core { cdj_reverse(core.pointer, Int32(deck), enabled) } }
    func jog(deck: Int, delta: Double, scratch: Bool) {
        guard valid(deck), delta.isFinite, let core else { return }
        jogCount &+= 1
        let now = DispatchTime.now().uptimeNanoseconds
        interactionUntil = now &+ 200_000_000
        configurePolling(active: true)
        if scratch {
            if nudgeDeadlines[deck] > 0 { nudgeDeadlines[deck] = 0; cdj_rate(core.pointer, Int32(deck), rates[deck]) }
            seek(deck: deck, seconds: position(deck: deck) + delta * 0.06); return
        }
        cdj_rate(core.pointer, Int32(deck), rates[deck] * min(1.2, max(0.8, 1 + delta * 0.025)))
        nudgeDeadlines[deck] = now &+ 160_000_000
    }
    func setPattern(enabled: Bool, bpm: Double, volume: Double) {
        patternEnabled = enabled
        if let core { cdj_pattern(core.pointer, enabled, bpm, volume) }
        if enabled { configurePolling(active: true) }
    }

    func startRecording(url: URL) throws {
        guard !isRecording, let recorder else { throw AudioFailure.message("Recorder unavailable or already recording.") }
        if !isRunning { try start() }
        try recorder.start(url: url)
        recordingURL = url; isRecording = true
        configurePolling(active: true)
    }
    func stopRecording() {
        guard isRecording else { return }
        let failure = recorder?.stop()
        isRecording = false
        if let failure { errorMessage = failure }
    }

    // File decoding and analysis are off the main and audio threads. Every file
    // is converted in bounded chunks to48k stereo, at most10minutes (~220MiB).
    // C++ caps aggregate track PCM at1GiB and reclaims retired buffers off RT.
    private nonisolated static func decode(url: URL) throws -> DecodedTrack {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch {
            let detail = error as NSError
            throw AudioFailure.message("Open audio failed (\(detail.domain), code \(detail.code)): \(detail.localizedDescription)")
        }
        let inputFormat = file.processingFormat
        let duration = Double(file.length) / inputFormat.sampleRate
        guard duration > 0, duration <= 600 else { throw AudioFailure.message("Audio must be nonempty and at most10minutes for this memory-bounded prototype.") }
        guard inputFormat.channelCount > 0, inputFormat.channelCount <= 8, inputFormat.sampleRate <= 384_000 else {
            throw AudioFailure.message("Supported input is one through eight channels at up to384kHz.")
        }
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            throw AudioFailure.message("This audio channel layout cannot be converted to stereo.")
        }
        let capacity = min(57_600_000, Int(ceil(duration * 48_000)) * 2 + 16_384)
        let samples = try [Float](unsafeUninitializedCapacity: capacity) { storage, initializedCount in
            var readError: Error?
            var finished = false
            while !finished {
                try Task.checkCancellation()
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { requested, state in
                    // AVAudioFile.read at exact EOF throws _GenericObjCError(0)
                    // on this SDK instead of returning an empty buffer. Check EOF
                    // BEFORE read, and never request past the remaining frames.
                    let remaining = file.length - file.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    do {
                        let frames = AVAudioFrameCount(min(AVAudioFramePosition(min(requested, input.frameCapacity)), remaining))
                        guard frames > 0 else { state.pointee = .noDataNow; return nil }
                        try file.read(into: input, frameCount: frames)
                        if input.frameLength == 0 { state.pointee = .endOfStream; return nil }
                        state.pointee = .haveData; return input
                    } catch {
                        let detail = error as NSError
                        readError = AudioFailure.message("Decode read failed at frame \(file.framePosition)/\(file.length) (\(detail.domain), code \(detail.code)): \(detail.localizedDescription)")
                        state.pointee = .endOfStream; return nil
                    }
                }
                if let readError { throw readError }
                if let conversionError {
                    throw AudioFailure.message("Stereo conversion failed (\(conversionError.domain), code \(conversionError.code)): \(conversionError.localizedDescription)")
                }
                if status == .error { throw AudioFailure.message("Audio conversion failed.") }
                if let channels = output.floatChannelData {
                    let count = Int(output.frameLength)
                    guard initializedCount + count * 2 <= storage.count else { throw AudioFailure.message("Decoded track exceeds the 10-minute PCM limit.") }
                    for i in 0..<count {
                        let l = channels[0][i], r = channels[1][i]
                        storage[initializedCount + i * 2] = l.isFinite ? l : 0
                        storage[initializedCount + i * 2 + 1] = r.isFinite ? r : 0
                    }
                    initializedCount += count * 2
                }
                finished = status == .endOfStream
                if !finished && output.frameLength == 0 && status == .inputRanDry && file.framePosition >= file.length { finished = true }
            }
        }
        guard samples.count >= 4 else { throw AudioFailure.message("The file decoded to no audio frames.") }
        let analysis = analyse(samples, title: url.deletingPathExtension().lastPathComponent, artist: "Local audio", knownBPM: nil)
        return DecodedTrack(samples: samples, analysis: analysis)
    }

    private nonisolated static func analyse(_ pcm: [Float], title: String, artist: String, knownBPM: Double?) -> TrackAnalysis {
        let frames = pcm.count / 2, bins = 768
        var waveform = [Float](repeating: 0, count: bins)
        for frame in 0..<frames {
            let bin = min(bins - 1, frame * bins / max(1, frames))
            waveform[bin] = max(waveform[bin], min(1, max(abs(pcm[frame * 2]), abs(pcm[frame * 2 + 1]))))
        }
        var bpm = knownBPM ?? 120
        if knownBPM == nil, frames >= 48_000 * 4 {
            let hop = 480, length = min(frames / hop, 12_000)
            var envelope = [Double](repeating: 0, count: length)
            var previous = 0.0
            for i in 0..<length {
                var energy = 0.0
                for f in 0..<hop { let x = Double(pcm[(i * hop + f) * 2]); energy += x * x }
                energy = sqrt(energy / Double(hop))
                envelope[i] = max(0, energy - previous); previous = energy
            }
            var best = 0.0, bestLag = 50
            for lag in 33...85 {
                var correlation = 0.0
                for i in lag..<length { correlation += envelope[i] * envelope[i - lag] }
                // Mild preference for the dance-tempo band; half/double ambiguity remains.
                let candidate = 6_000.0 / Double(lag)
                correlation *= candidate >= 90 && candidate <= 155 ? 1.05 : 1
                if correlation > best { best = correlation; bestLag = lag }
            }
            bpm = best > 0.000001 ? 6_000 / Double(bestLag) : 120
        }
        return TrackAnalysis(title: title, artist: artist, duration: Double(frames) / 48_000, bpm: bpm, waveform: waveform, sampleRate: 48_000)
    }

    private nonisolated static func makeDemo(variant: Int) throws -> DecodedTrack {
        let bpm = variant == 0 ? 120.0 : 128.0, seconds = 64, sr = 48_000
        var pcm = [Float](repeating: 0, count: seconds * sr * 2)
        let root = variant == 0 ? 55.0 : 61.7354
        let frequencies = [0.0, 0, 7, 0, 3, 3, 10, 7].map { root * pow(2, $0 / 12) }
        let padMinor = root * 4 * pow(2, 3.0 / 12)
        // The same short envelopes repeat for 128/136 beats. Build them once
        // instead of evaluating six exponentials for every stereo frame.
        let beatFrames = Int((Double(sr) * 60 / bpm).rounded())
        let halfFrames = beatFrames / 2
        var kicks = [Double](repeating: 0, count: beatFrames + 1)
        var snares = kicks, bassEnvelope = kicks
        var hats = [Double](repeating: 0, count: halfFrames + 1), leadEnvelope = hats
        for i in 0...beatFrames {
            let age = Double(i) / Double(sr)
            kicks[i] = sin(2 * Double.pi * (48 * age + 3 * (1 - exp(-35 * age)))) * exp(-18 * age) * 0.42
            snares[i] = exp(-30 * age) * 0.13
            bassEnvelope[i] = exp(-3 * age) * 0.13
        }
        for i in 0...halfFrames {
            let age = Double(i) / Double(sr)
            hats[i] = exp(-100 * age) * 0.07
            leadEnvelope[i] = exp(-12 * age) * 0.025
        }
        var random: UInt32 = 0xC0123456 &+ UInt32(variant)
        for i in 0..<(seconds * sr) {
            if i & 8_191 == 0 { try Task.checkCancellation() }
            let t = Double(i) / Double(sr), beat = t * bpm / 60
            let beatAge = (beat - floor(beat)) * 60 / bpm
            let halfAge = (beat * 2 - floor(beat * 2)) * 30 / bpm
            let b = min(beatFrames, max(0, Int((beatAge * Double(sr)).rounded())))
            let h = min(halfFrames, max(0, Int((halfAge * Double(sr)).rounded())))
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            let noise = Double(random) / Double(UInt32.max) * 2 - 1
            let kick = kicks[b]
            let snare = Int(floor(beat)) % 4 == 1 || Int(floor(beat)) % 4 == 3 ? noise * snares[b] : 0
            let hat = noise * hats[h]
            let f = frequencies[Int(floor(beat / 2)) % frequencies.count]
            let bass = (sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * bassEnvelope[b]
            let pad = (sin(2 * .pi * root * 4 * t) + sin(2 * .pi * padMinor * t)) * 0.025
            let lead = sin(2 * .pi * f * 8 * t) * leadEnvelope[h]
            let fade = min(1, t / 0.015) * min(1, (Double(seconds) - t) / 0.3)
            pcm[i * 2] = Float((kick + snare + hat + bass + pad + lead) * fade)
            pcm[i * 2 + 1] = Float((kick + snare + hat + bass + pad * 0.85 + lead * 0.7) * fade)
        }
        return DecodedTrack(samples: pcm, analysis: analyse(pcm, title: variant == 0 ? "Midnight Circuit" : "Tidal Motion", artist: "Contour · original generated demo", knownBPM: bpm))
    }
}
