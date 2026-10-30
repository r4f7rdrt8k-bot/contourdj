import Foundation
import Combine
import CoreMIDI
import Darwin

enum MIDIValueMode: String, Codable, CaseIterable, Sendable {
    case absolute7, paired14, relativeTwosComplement, button
}

/// Channel numbers are zero based internally. `source` is a name filter, not a USB VID claim.
struct MIDIMapping: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var action: String
    var description: String
    var source: String = ""
    var excludingSource: String = ""
    var channel: Int = 0
    var status: Int = 0xB0
    var number: Int = 0
    var mode: MIDIValueMode = .absolute7
    var lsbNumber: Int? = nil
    var maximum: Double = 127
    var scale: Double = 1
}

/// MIDI 1 byte-stream decoder. Running status survives packet boundaries per source;
/// real-time bytes do not disturb a message and SysEx/system-common are not controls.
private struct MIDIByteDecoder {
    var runningStatus: UInt8?
    var pendingStatus: UInt8?
    var data: [UInt8] = []
    var systemExclusive = false
    var systemRemaining = 0

    mutating func feed(_ bytes: [UInt8]) -> [(UInt8, UInt8, UInt8)] {
        var messages: [(UInt8, UInt8, UInt8)] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte & 0x80 != 0 {
                data.removeAll(keepingCapacity: true)
                if byte == 0xF0 {
                    systemExclusive = true; runningStatus = nil; pendingStatus = nil
                    systemRemaining = 0
                } else if byte >= 0xF0 {
                    systemExclusive = false; runningStatus = nil; pendingStatus = nil
                    systemRemaining = byte == 0xF2 ? 2 : (byte == 0xF1 || byte == 0xF3 ? 1 : 0)
                } else {
                    systemExclusive = false; systemRemaining = 0
                    runningStatus = byte; pendingStatus = byte
                }
                continue
            }
            if systemExclusive { continue }
            if systemRemaining > 0 { systemRemaining -= 1; continue }
            guard let status = pendingStatus ?? runningStatus else { continue }
            pendingStatus = status
            data.append(byte)
            let length = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            if data.count == length {
                messages.append((status, data[0], length == 2 ? data[1] : 0))
                data.removeAll(keepingCapacity: true); pendingStatus = nil
            }
        }
        return messages
    }
}

private struct MIDIInbound: Sendable {
    let endpoint: MIDIEndpointRef
    let bytes: [UInt8]
    let receivedAt: TimeInterval
    let sourceName: String?
}

private enum MIDIHostClock {
    static let secondsPerTick: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1_000_000_000
    }()

    static func eventTime(_ timestamp: MIDITimeStamp, receipt: TimeInterval) -> TimeInterval {
        guard timestamp != 0 else { return receipt }
        let current = mach_absolute_time()
        guard timestamp <= current else { return receipt }
        return receipt - Double(current - timestamp) * secondsPerTick
    }
}

/// Callback threads append FIFO data under a short lock. Only one main-actor
/// worker is scheduled at a time; each pass has bounded byte/packet work.
private final class MIDIIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [MIDIInbound] = []
    private var head = 0
    private var scheduled = false
    private var pendingBytes = 0
    private var peakBytes = 0
    private var workers = 0

    func append(_ packet: MIDIInbound) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !packet.bytes.isEmpty else { return false }
        // MIDI permits packet-spanning messages, so splitting a large packet
        // bounds drain work without interpreting or discarding any message.
        for offset in stride(from: 0, to: packet.bytes.count, by: 4096) {
            let end = min(offset + 4096, packet.bytes.count)
            let bytes = offset == 0 && end == packet.bytes.count ? packet.bytes : Array(packet.bytes[offset..<end])
            packets.append(MIDIInbound(endpoint: packet.endpoint, bytes: bytes,
                receivedAt: packet.receivedAt, sourceName: packet.sourceName))
        }
        pendingBytes += packet.bytes.count
        peakBytes = max(peakBytes, pendingBytes)
        guard !scheduled else { return false }
        scheduled = true; workers += 1
        return true
    }

    func take() -> [MIDIInbound]? {
        lock.lock(); defer { lock.unlock() }
        guard head < packets.count else {
            packets.removeAll(keepingCapacity: true); head = 0; scheduled = false
            return nil
        }
        var batch: [MIDIInbound] = []
        var bytes = 0
        while head < packets.count && batch.count < 32 {
            let packet = packets[head]
            guard bytes + packet.bytes.count <= 8192 else { break }
            batch.append(packet); bytes += packet.bytes.count; head += 1
        }
        pendingBytes -= bytes
        if head >= 1024 && head * 2 >= packets.count { packets.removeFirst(head); head = 0 }
        return batch
    }

    func statistics() -> (active: Bool, pendingBytes: Int, peakBytes: Int, workers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (scheduled, pendingBytes, peakBytes, workers)
    }
}

private struct MIDISourceChannel: Hashable {
    let endpoint: MIDIEndpointRef
    let channel: Int
}
private struct MIDIControlKey: Hashable {
    let group: MIDISourceChannel
    let number: Int
}
private struct MIDIHeldKey: Hashable {
    let endpoint: MIDIEndpointRef
    let action: String
}
private struct MIDIRoute {
    let name: String
    let isJog: Bool
    let isMixer: Bool
    var controls: [Int: [MIDIMapping]] = [:]
    var lsbControls: Set<Int> = []
}
private enum MIDIDiagnostic {
    case text(String)
    case input(name: String, channel: Int, kind: Int, number: UInt8, value: UInt8, action: String?, output: Double?)

    var text: String {
        switch self {
        case .text(let value): return value
        case let .input(name, channel, kind, number, value, action, output):
            let raw = "\(name) · ch\(channel + 1) \(kind == 0xB0 ? "CC" : "Note")\(number) \(kind == 0x80 ? 0 : Int(value))"
            guard let action, let output else { return raw }
            return "\(raw) → \(action) \(String(format: "%.3f", output))"
        }
    }
}

@MainActor
final class MIDIController: ObservableObject {
    @Published var sources: [String] = []
    @Published var lastMessage = "Connect a USB MIDI controller, or use Test Controls."
    @Published var isLearning = false
    @Published var mappings: [MIDIMapping] { didSet { mappingRevision &+= 1; routes.removeAll(); scheduleMappingSave() } }
    @Published var eventLog: [String] = []
    var onAction: ((String, Double) -> Void)?

    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private var connected: [MIDIEndpointRef: String] = [:]
    private var decoders: [MIDIEndpointRef: MIDIByteDecoder] = [:]
    private var values: [MIDIControlKey: UInt8] = [:]
    private var held: [MIDIHeldKey: Set<String>] = [:]
    private var shiftSources: Set<MIDIEndpointRef> = []
    private var heartbeats: [MIDISourceChannel: TimeInterval] = [:]
    private var jogTouchActions: [MIDISourceChannel: Set<String>] = [:]
    private var routes: [MIDIEndpointRef: MIDIRoute] = [:]
    private var mappingRevision = 0
    private let ingress = MIDIIngress()
    private var drainBatches = 0
    private var maximumDrainBytes = 0
    private var diagnostic: MIDIDiagnostic?
    private var diagnosticTask: Task<Void, Never>?
    private var lastDiagnosticTime: TimeInterval = -.infinity
    private var diagnosticPublications = 0
    private var mappingSaveTask: Task<Void, Never>?
    private var learningAction: String?
    private var watchdog: Timer?
    private let persistsMappings: Bool
    private static let persistenceKey = "Contour.MIDIMappings.v1"

    init(connectHardware: Bool = true, persistMappings: Bool = true) {
        persistsMappings = persistMappings
        if persistMappings, let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
           let saved = try? JSONDecoder().decode([MIDIMapping].self, from: data) {
            mappings = saved
        } else {
            mappings = Self.defaultMappings()
        }
        guard connectHardware else { return }
        let result = MIDIClientCreateWithBlock("Contour MIDI" as CFString, &client) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        guard result == noErr else {
            record("CoreMIDI unavailable (\(result)); Test Controls remain available.")
            return
        }
        let ingress = self.ingress
        let portResult = MIDIInputPortCreateWithBlock(client, "Contour input" as CFString, &input) { [weak self] packetList, context in
            let endpoint = MIDIEndpointRef(UInt(bitPattern: context))
            let receivedAt = ProcessInfo.processInfo.systemUptime
            var startWorker = false
            let offset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
            var packet = UnsafeRawPointer(packetList).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<packetList.pointee.numPackets {
                let length = Int(packet.pointee.length)
                let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
                let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                let bytes = Array(UnsafeBufferPointer(start: data, count: length))
                let eventTime = MIDIHostClock.eventTime(packet.pointee.timeStamp, receipt: receivedAt)
                if ingress.append(MIDIInbound(endpoint: endpoint, bytes: bytes, receivedAt: eventTime, sourceName: nil)) { startWorker = true }
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
            // CoreMIDI callbacks copy only; all published state and routing stay on MainActor.
            if startWorker {
                Task { @MainActor [weak self] in await self?.drainIngress() }
            }
        }
        guard portResult == noErr else {
            record("Cannot create MIDI input (\(portResult)); Test Controls remain available.")
            return
        }
        refresh()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkHeartbeats() }
        }
    }

    deinit {
        watchdog?.invalidate()
        diagnosticTask?.cancel()
        mappingSaveTask?.cancel()
        if input != 0 { MIDIPortDispose(input) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Connects new sources and disconnects vanished ones. Nothing is sent to hardware.
    func refresh() {
        guard input != 0 else { return }
        var available: [MIDIEndpointRef: String] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            let name = Self.name(of: endpoint)
            available[endpoint] = name
            if connected[endpoint] == nil {
                let result = MIDIPortConnectSource(input, endpoint, UnsafeMutableRawPointer(bitPattern: UInt(endpoint)))
                if result == noErr { record("Connected: \(name)") }
                else { available.removeValue(forKey: endpoint); record("Cannot connect \(name) (\(result))") }
            }
        }
        for (endpoint, name) in connected where available[endpoint] == nil {
            MIDIPortDisconnectSource(input, endpoint)
            releaseSource(endpoint)
            decoders.removeValue(forKey: endpoint)
            routes.removeValue(forKey: endpoint)
            record("Disconnected: \(name)")
        }
        connected = available
        let names = available.values.sorted()
        if sources != names { sources = names }
    }

    func learn(action: String) {
        guard !action.isEmpty else { return }
        learningAction = action; isLearning = true
        record("Learning \(action): move or press a MIDI control.")
    }

    func cancelLearn() { learningAction = nil; isLearning = false }

    func resetMappings() {
        releaseAll()
        mappings = Self.defaultMappings(); cancelLearn()
        record("Restored YaSushi mixer and jog defaults.")
    }

    func removeMapping(id: String) {
        releaseAll()
        mappings.removeAll { $0.id == id }
    }

    func updateMapping(_ mapping: MIDIMapping) {
        guard let index = mappings.firstIndex(where: { $0.id == mapping.id }),
              (0...15).contains(mapping.channel), (0...127).contains(mapping.number),
              [0x90, 0xB0].contains(mapping.status), mapping.scale.isFinite,
              mapping.maximum.isFinite, mapping.maximum > 0,
              mapping.lsbNumber.map({ (0...127).contains($0) }) ?? true else { return }
        releaseAll(); mappings[index] = mapping
    }

    /// Optional application-termination hook. Normal edits coalesce for 100 ms;
    /// a deliberate exit can commit the latest snapshot before that delay ends.
    func flushMappingChanges() {
        mappingSaveTask?.cancel(); mappingSaveTask = nil
        guard persistsMappings, let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    /// UI action simulation deliberately bypasses hardware/heartbeat checks.
    func simulate(action: String, value: Double) {
        guard value.isFinite else { return }
        record("TEST \(action) = \(Self.pretty(value))")
        onAction?(action, value)
    }

    /// Deterministic byte-level test injection also exercises running status and mappings.
    /// It does not create a CoreMIDI device or send bytes outside Contour.
    func inject(bytes: [UInt8], source: String = "Ya$ushi Controls") {
        let endpoint: MIDIEndpointRef = source.lowercased().contains("jog") ? 0xFFFFFFFE : 0xFFFFFFFF
        consume(bytes: bytes, endpoint: endpoint, nameOverride: source)
    }

    /// Exercises the real callback FIFO without opening a port or sending MIDI.
    nonisolated func enqueueForTesting(bytes: [UInt8], source: String = "Ya$ushi Controls", receivedAt: TimeInterval? = nil) {
        let endpoint: MIDIEndpointRef = source.lowercased().contains("jog") ? 0xFFFFFFFE : 0xFFFFFFFF
        if ingress.append(MIDIInbound(endpoint: endpoint, bytes: bytes,
            receivedAt: receivedAt ?? ProcessInfo.processInfo.systemUptime, sourceName: source)) {
            Task { @MainActor [weak self] in await self?.drainIngress() }
        }
    }

    func waitForPendingInput() async {
        while ingress.statistics().active { await Task.yield() }
    }

    var performanceStatistics: [String: Int] {
        let queue = ingress.statistics()
        return ["pending_bytes": queue.pendingBytes, "peak_pending_bytes": queue.peakBytes,
            "scheduled_workers": queue.workers, "drain_batches": drainBatches,
            "maximum_drain_bytes": maximumDrainBytes, "diagnostic_publications": diagnosticPublications]
    }

    private func drainIngress() async {
        while let batch = ingress.take() {
            drainBatches += 1
            maximumDrainBytes = max(maximumDrainBytes, batch.reduce(0) { $0 + $1.bytes.count })
            for packet in batch {
                // A vanished device's already queued presses must not re-arm
                // a held control after refresh() has issued its releases.
                if packet.sourceName == nil && connected[packet.endpoint] == nil { continue }
                consume(bytes: packet.bytes, endpoint: packet.endpoint,
                    nameOverride: packet.sourceName, receivedAt: packet.receivedAt)
            }
            // A queued worker replaces one Task per callback. Yield between
            // bounded passes so UI and touch/watchdog work can also run.
            await Task.yield()
        }
    }

    private func consume(bytes: [UInt8], endpoint: MIDIEndpointRef, nameOverride: String? = nil, receivedAt: TimeInterval? = nil) {
        let name = nameOverride ?? connected[endpoint] ?? Self.name(of: endpoint)
        var route = route(for: endpoint, name: name)
        var revision = mappingRevision
        var decoder = decoders[endpoint] ?? MIDIByteDecoder()
        let messages = decoder.feed(bytes)
        decoders[endpoint] = decoder
        let now = ProcessInfo.processInfo.systemUptime
        for (status, number, value) in messages {
            if revision != mappingRevision { route = self.route(for: endpoint, name: name); revision = mappingRevision }
            process(status: status, number: number, value: value, endpoint: endpoint,
                route: route, now: now, receivedAt: receivedAt ?? now)
        }
    }

    private func route(for endpoint: MIDIEndpointRef, name: String) -> MIDIRoute {
        if let route = routes[endpoint], route.name == name { return route }
        let normalized = Self.normalized(name)
        let isJog = normalized.contains("yasushi") && normalized.contains("jog")
        var route = MIDIRoute(name: name, isJog: isJog, isMixer: normalized.contains("yasushi") && !isJog)
        for mapping in mappings where Self.matchesSource(mapping, name: name) {
            route.controls[Self.controlIndex(channel: mapping.channel, kind: mapping.status, number: mapping.number), default: []].append(mapping)
            if let number = mapping.lsbNumber { route.lsbControls.insert(mapping.channel * 128 + number) }
        }
        routes[endpoint] = route
        return route
    }

    private static func controlIndex(channel: Int, kind: Int, number: Int) -> Int {
        (channel << 16) | (kind << 8) | number
    }

    private func process(status: UInt8, number: UInt8, value: UInt8, endpoint: MIDIEndpointRef, route: MIDIRoute, now: TimeInterval, receivedAt: TimeInterval) {
        let channel = Int(status & 0x0F), kind = Int(status & 0xF0)
        guard kind == 0xB0 || kind == 0x90 || kind == 0x80 else { return }
        let name = route.name
        let key = MIDISourceChannel(endpoint: endpoint, channel: channel)
        if route.isJog && channel < 2 && kind == 0xB0 && number == 33 {
            if value == 1 {
                if let prior = heartbeats[key], now - prior >= 0.5 { releaseJog(key: key, deck: channel) }
                // Preserve CoreMIDI event time (callback time if unspecified):
                // draining an old backlog must not refresh a stale heartbeat.
                heartbeats[key] = min(receivedAt, now)
            }
            return // Do not let periodic heartbeat steal Learn or obscure a control event.
        }
        if kind == 0xB0 { values[MIDIControlKey(group: key, number: Int(number))] = value }

        if let action = learningAction, !(kind != 0xB0 && (kind == 0x80 || value == 0)) {
            let mixer = route.isMixer
            // The mixer sends LSB before MSB, so wait for the committing MSB.
            if mixer && kind == 0xB0 && (16...28).contains(Int(number)) { return }
            let raw = MIDIDiagnostic.input(name: name, channel: channel, kind: kind, number: number, value: value, action: nil, output: nil).text
            var mapping = MIDIMapping(id: UUID().uuidString, action: action, description: raw)
            mapping.source = name; mapping.channel = channel
            mapping.status = kind == 0x80 ? 0x90 : kind; mapping.number = Int(number)
            if kind != 0xB0 { mapping.mode = .button }
            else if mixer && number < 13 {
                mapping.mode = .paired14; mapping.lsbNumber = Int(number) + 16; mapping.maximum = 16380
            } else if action.hasSuffix(".jog") || action == "library.encoder" {
                mapping.mode = .relativeTwosComplement
                mapping.scale = route.isJog && number == 32 ? 1.0 / 64 : 1
            }
            // A learned physical input replaces its old assignment; the target action
            // replaces its other assignments. Relearning cannot fire two actions at once.
            releaseAll()
            mappings.removeAll { $0.action == action || (Self.matchesSource($0, name: name) && $0.channel == channel && $0.status == mapping.status && $0.number == mapping.number) }
            mappings.append(mapping); cancelLearn()
            record("Mapped \(raw) → \(action)")
            return
        }

        let index = Self.controlIndex(channel: channel, kind: kind == 0x80 ? 0x90 : kind, number: Int(number))
        let matches = route.controls[index] ?? []
        guard !matches.isEmpty else {
            // Paired LSBs are state updates, not separate controls in the event log.
            if !route.lsbControls.contains(channel * 128 + Int(number)) {
                recordInput(name: name, channel: channel, kind: kind, number: number, value: value)
            }
            return
        }
        for mapping in matches {
            var output: Double
            switch mapping.mode {
            case .absolute7: output = Double(value) / 127
            case .paired14:
                guard let lsb = mapping.lsbNumber, let low = values[MIDIControlKey(group: key, number: lsb)] else { continue }
                output = min(1, max(0, Double(Int(value) * 128 + Int(low)) / mapping.maximum))
            case .relativeTwosComplement:
                guard value != 0 && value != 64 else { continue }
                output = Double(value < 64 ? Int(value) : Int(value) - 128) * mapping.scale
            case .button: output = kind == 0x80 || value == 0 ? 0 : 1
            }
            if route.isJog && channel < 2 && (number == 32 || number == 64) {
                if output != 0 && !(heartbeats[key].map { now - $0 < 0.5 } ?? false) {
                    releaseJog(key: key, deck: channel)
                    recordInput(name: name, channel: channel, kind: kind, number: number, value: value, action: "ignored stale jog", output: output)
                    continue
                }
                if number == 64 {
                    if output > 0 && value != 127 { continue }
                    if mapping.action.hasSuffix(".touch") || mapping.action.hasSuffix(".cue") {
                        if output > 0 { jogTouchActions[key, default: []].insert(mapping.action) }
                        else { jogTouchActions[key]?.remove(mapping.action) }
                    }
                }
            }
            var action = mapping.action
            if action == "controller.shift" {
                if output > 0 { shiftSources.insert(endpoint) } else { shiftSources.remove(endpoint) }
                recordInput(name: name, channel: channel, kind: kind, number: number, value: value, action: action, output: output)
                continue
            }
            let shifted = shiftSources.contains(endpoint)
            if action.hasSuffix(".beatjump") { output = output > 0 ? (shifted ? 1 : 4) * mapping.scale : 0 }
            if shifted && action.hasSuffix(".play") { action = action.replacingOccurrences(of: ".play", with: ".sync") }
            if shifted && action.hasSuffix(".jog") { output *= 5 }
            if shifted && action == "library.encoder" { action = "library.focus" }
            if mapping.mode == .button {
                let sourceKey = MIDIHeldKey(endpoint: endpoint, action: action)
                var active = held[sourceKey] ?? []
                let wasHeld = !active.isEmpty
                if output > 0 { active.insert(mapping.id) } else { active.remove(mapping.id) }
                held[sourceKey] = active
                if action.hasSuffix(".touch") || action.hasSuffix(".cue") {
                    guard wasHeld != !active.isEmpty else { continue }
                    output = active.isEmpty ? 0 : 1
                } else if output == 0 { continue }
            }
            recordInput(name: name, channel: channel, kind: kind, number: number, value: value, action: action, output: output)
            onAction?(action, output)
        }
    }

    private func checkHeartbeats() {
        let now = ProcessInfo.processInfo.systemUptime
        for key in Array(heartbeats.keys) where now - (heartbeats[key] ?? 0) >= 0.5 {
            releaseJog(key: key, deck: key.channel)
            heartbeats.removeValue(forKey: key)
        }
    }

    private func releaseJog(key: MIDISourceChannel, deck: Int) {
        guard let actions = jogTouchActions.removeValue(forKey: key), !actions.isEmpty else { return }
        for action in actions {
            held[MIDIHeldKey(endpoint: key.endpoint, action: action)] = []
            onAction?(action, 0)
        }
        record("Jog deck \(deck + 1): released stale press.")
    }

    private func releaseSource(_ endpoint: MIDIEndpointRef) {
        for (key, active) in held where key.endpoint == endpoint && !active.isEmpty {
            let action = key.action
            if action.hasSuffix(".touch") || action.hasSuffix(".cue") { onAction?(action, 0) }
        }
        held = held.filter { $0.key.endpoint != endpoint }
        values = values.filter { $0.key.group.endpoint != endpoint }
        shiftSources.remove(endpoint)
        for deck in 0..<2 { let key = MIDISourceChannel(endpoint: endpoint, channel: deck); releaseJog(key: key, deck: deck); heartbeats.removeValue(forKey: key) }
    }

    private func releaseAll() {
        let endpoints = Set(held.keys.map(\.endpoint))
        for endpoint in endpoints { releaseSource(endpoint) }
        shiftSources.removeAll(); values.removeAll()
    }

    private func scheduleMappingSave() {
        guard persistsMappings else { return }
        // Learn removes an old mapping then appends a new one. Coalesce that
        // edit into one write, outside the synchronous MIDI routing call.
        mappingSaveTask?.cancel()
        let snapshot = mappings
        mappingSaveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot) }.value
            guard !Task.isCancelled, let data else { return }
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
    }

    private func record(_ text: String) {
        // Human-initiated status (Learn, connection, reset) remains immediate.
        diagnosticTask?.cancel(); diagnosticTask = nil
        diagnostic = .text(text)
        publishDiagnostic()
    }

    private func recordInput(name: String, channel: Int, kind: Int, number: UInt8, value: UInt8, action: String? = nil, output: Double? = nil) {
        // Keep structured data, not a formatted string, on the high-rate path.
        // Diagnostics sample the newest event at 20 Hz; audio/control actions
        // above are never throttled, coalesced or dropped.
        diagnostic = .input(name: name, channel: channel, kind: kind, number: number, value: value, action: action, output: output)
        let remaining = 0.05 - (ProcessInfo.processInfo.systemUptime - lastDiagnosticTime)
        if remaining <= 0 {
            diagnosticTask?.cancel(); diagnosticTask = nil
            publishDiagnostic(); return
        }
        guard diagnosticTask == nil else { return }
        diagnosticTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            self?.diagnosticTask = nil
            self?.publishDiagnostic()
        }
    }

    private func publishDiagnostic() {
        guard let diagnostic else { return }
        self.diagnostic = nil
        lastDiagnosticTime = ProcessInfo.processInfo.systemUptime
        let text = diagnostic.text
        if lastMessage != text { lastMessage = text }
        // Assign once rather than publishing an insertion and a trim separately.
        eventLog = [text] + eventLog.prefix(199)
        diagnosticPublications += 1
    }

    private static func normalized(_ name: String) -> String { name.lowercased().replacingOccurrences(of: "$", with: "s") }
    private static func matchesSource(_ mapping: MIDIMapping, name: String) -> Bool {
        let name = normalized(name)
        return (mapping.source.isEmpty || name.contains(normalized(mapping.source))) &&
            (mapping.excludingSource.isEmpty || !name.contains(normalized(mapping.excludingSource)))
    }
    private static func pretty(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func name(of endpoint: MIDIEndpointRef) -> String {
        for key in [kMIDIPropertyDisplayName, kMIDIPropertyName] {
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(endpoint, key, &name) == noErr, let name { return name.takeRetainedValue() as String }
        }
        return "MIDI source \(endpoint)"
    }

    static func defaultMappings() -> [MIDIMapping] {
        var result: [MIDIMapping] = []
        func add(_ action: String, _ number: Int, _ description: String, mode: MIDIValueMode = .button, scale: Double = 1) {
            result.append(MIDIMapping(id: "yasushi-\(mode.rawValue)-\(number)", action: action, description: description,
                source: "yasushi", excludingSource: "jog", channel: 0, status: mode == .button ? 0x90 : 0xB0,
                number: number, mode: mode, scale: scale))
        }
        let analogs = ["deck0.high", "deck0.mid", "deck0.low", "deck0.filter", "deck1.high", "deck1.mid", "deck1.low", "deck1.filter", "deck0.volume", "deck1.volume", "deck0.rate", "deck1.rate", "mixer.crossfader"]
        for (cc, action) in analogs.enumerated() {
            result.append(MIDIMapping(id: "yasushi-analog-\(cc)", action: action,
                description: "YaSushi ch1 CC\(cc) + LSB\(cc + 16) · 14-bit", source: "yasushi", excludingSource: "jog",
                channel: 0, status: 0xB0, number: cc, mode: .paired14, lsbNumber: cc + 16, maximum: 16380))
        }
        let names = ["beatjump", "stop", "play", "cue", "beatjump", "loop", "cue", "play", "effectsOff", "load"]
        for deck in 0..<2 {
            for (index, name) in names.enumerated() {
                let note = 32 + deck * 10 + index
                add("deck\(deck).\(name)", note, "YaSushi deck \(deck + 1) Note\(note) · \(name)", scale: index == 0 ? -1 : 1)
            }
            add("deck\(deck).jog", 64 + deck, "YaSushi encoder \(deck + 1) CC\(64 + deck) · ±1", mode: .relativeTwosComplement)
            add("deck\(deck).touch", 55 + deck, "YaSushi jog press Note\(55 + deck)")
            for (cc, action, mode, scale) in [(32, "jog", MIDIValueMode.relativeTwosComplement, 1.0 / 64), (64, "touch", .button, 1.0)] {
                result.append(MIDIMapping(id: "yasushi-jog-\(deck)-\(cc)", action: "deck\(deck).\(action)",
                    description: "YaSushi Jog ch\(deck + 1) \(mode == .button ? "Note" : "CC")\(cc)", source: "yasushi jog",
                    channel: deck, status: mode == .button ? 0x90 : 0xB0, number: cc, mode: mode, scale: scale))
            }
        }
        add("controller.shift", 52, "YaSushi SHIFT Note52")
        add("library.back", 53, "YaSushi browser back Note53")
        add("library.load", 54, "YaSushi browser confirm Note54")
        add("library.encoder", 66, "YaSushi browser encoder CC66 · ±1", mode: .relativeTwosComplement)
        return result
    }
}
