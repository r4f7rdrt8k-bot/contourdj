import Foundation
import Combine

/// Playback advances independently from deck controls, so a playhead update does
/// not invalidate transport buttons, EQ controls, library rows or app menus.
@MainActor final class DeckClock: ObservableObject {
    @Published private(set) var position: Double = 0
    func update(_ value: Double) {
        guard value.isFinite, abs(position - value) > 0.00001 else { return }
        position = value
    }
}

@MainActor final class MasterMeterState: ObservableObject {
    @Published private(set) var peak: Float = 0
    func update(_ value: Float) {
        let next = max(0, min(1, value.isFinite ? value : 0))
        // Meter resolution exceeds the18 display segments; suppress invisible
        // sub-millidecimal changes and identical silence notifications.
        if abs(next - peak) >= 0.002 || (next == 0 && peak != 0) { peak = next }
    }
}

@MainActor final class MixControlState: ObservableObject {
    @Published var crossfader: Double = 0.5
    @Published var masterVolume: Double = 0.65
}

/// Serial, coalesced persistence keeps encoding and atomic disk writes off the
/// input/UI thread. Latest snapshots are value types, never mutable UI objects.
final class ModelPersistence: @unchecked Sendable {
    private struct Snapshot {
        let tracks: [LibraryTrack]
        let preparation: [String:SavedPreparation]
    }
    private let directory: URL
    private let queue = DispatchQueue(label:"contour.persistence",qos:.utility)
    private let lock = NSLock()
    private var pending: Snapshot?
    private var scheduled = false
    init(directory:URL) { self.directory = directory }
    func schedule(tracks:[LibraryTrack],preparation:[String:SavedPreparation]) {
        lock.lock()
        pending = Snapshot(tracks:tracks,preparation:preparation)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.asyncAfter(deadline:.now()+0.15) { [self] in writePending() } }
    }
    private func writePending() {
        lock.lock();let snapshot = pending;pending = nil;scheduled = false;lock.unlock()
        guard let snapshot else { return }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot.tracks) { try? data.write(to:directory.appendingPathComponent("library.json"),options:.atomic) }
        if let data = try? encoder.encode(snapshot.preparation) { try? data.write(to:directory.appendingPathComponent("preparation.json"),options:.atomic) }
    }
    func flush() { queue.sync { writePending() } }
}
