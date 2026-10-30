import Foundation
import SwiftUI
import Combine

@main struct ModelBenchmark {
    @MainActor static func main() {
        let model = PerformanceModel()
        model.decks[0].duration = 64;model.decks[1].duration = 64
        var rootNotifications = 0, deckNotifications = 0
        let a = model.objectWillChange.sink { rootNotifications += 1 }
        let b = model.decks[0].objectWillChange.sink { deckNotifications += 1 }
        let c = model.decks[1].objectWillChange.sink { deckNotifications += 1 }
        let count = 10_000
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<count { model.tick() }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var result:[String:Any] = ["idle_ticks":count,"idle_seconds":elapsed,"idle_root_notifications":rootNotifications,"idle_deck_notifications":deckNotifications]
        rootNotifications = 0;deckNotifications = 0
        let movingStart = ProcessInfo.processInfo.systemUptime
        for i in 0..<count { model.audio.seek(deck:0,seconds:Double(i%6000)/100);model.tick() }
        result["moving_seconds"] = ProcessInfo.processInfo.systemUptime-movingStart
        result["moving_root_notifications"] = rootNotifications
        result["moving_deck_notifications"] = deckNotifications
        result["final_position"] = model.decks[0].position
        model.tracks = (0..<5000).map { i in LibraryTrack(title:"Track \(5000-i)",artist:"Generated \(i%30)",duration:60,bpm:120) }
        var checksum=0
        let libraryStart=ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {checksum += model.filteredTracks.count}
        result["library_queries"] = 100;result["library_tracks"] = 5000
        result["library_seconds"] = ProcessInfo.processInfo.systemUptime-libraryStart
        result["library_checksum"] = checksum
        let data = try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!)
        withExtendedLifetime([a,b,c]) {}
    }
}
