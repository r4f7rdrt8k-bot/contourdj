import Foundation
import SwiftUI
import Combine

@main struct ModelChecks {
    @MainActor static func main() throws {
        let m=PerformanceModel()
        let a=LibraryTrack(title:"Alpha",artist:"One",duration:60,bpm:120)
        let b=LibraryTrack(title:"Beta",artist:"Two",duration:60,bpm:128,isRecording:true)
        let c=LibraryTrack(title:"Gamma",artist:"One",duration:60,bpm:100)
        m.tracks=[c,b,a]
        precondition(m.filteredTracks.map(\.title)==["Alpha","Beta","Gamma"])
        m.search="One";precondition(m.filteredTracks.map(\.title)==["Alpha","Gamma"])
        m.search="";m.section="Recordings";precondition(m.filteredTracks.map(\.title)==["Beta"])
        m.section="Library";m.sortOrder=[KeyPathComparator(\LibraryTrack.title,order:.reverse)]
        precondition(m.filteredTracks.map(\.title)==["Gamma","Beta","Alpha"])
        m.selectedTrack=c.id;m.handleMIDI("library.encoder",1);precondition(m.selectedTrack==b.id)
        m.tracks[1].title="Zeta";precondition(m.filteredTracks.first?.title=="Zeta")
        var root=0,controls=0,clock=0
        let s1=m.objectWillChange.sink {root+=1}
        let s2=m.decks[0].objectWillChange.sink {controls+=1}
        let s3=m.decks[0].clock.objectWillChange.sink {clock+=1}
        m.decks[0].duration=64;controls=0
        m.audio.seek(deck:0,seconds:12.5);m.tick()
        precondition(m.decks[0].position==12.5 && clock==1 && root==0 && controls==0)
        m.tick();precondition(clock==1 && root==0 && controls==0)
        m.setCrossfader(0.25);precondition(m.crossfader==0.25 && root==0)
        m.setMaster(0.4);precondition(m.masterVolume==0.4 && root==0)
        m.save();m.shutdown()
        let saved=try JSONDecoder().decode([LibraryTrack].self,from:Data(contentsOf:m.dataDirectory.appendingPathComponent("library.json")))
        precondition(saved.map(\.title)==m.tracks.map(\.title))
        withExtendedLifetime([s1,s2,s3]) {}
        print("PASS: cache invalidation on search/section/sort/metadata; MIDI visible-order browse; isolated and unchanged playhead notifications; isolated crossfader/master; latest asynchronous persistence flushed on shutdown.")
    }
}
