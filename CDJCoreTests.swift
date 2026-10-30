import XCTest
import Foundation
import CDJCore

final class CDJCoreTests: XCTestCase {
    private func engine(_ sampleRate: Double = 8_000) -> OpaquePointer { cdj_create(sampleRate)! }
    private func load(_ e: OpaquePointer, _ samples: [Float], deck: Int32 = 0, rate: Double = 8_000) {
        XCTAssertTrue(samples.withUnsafeBufferPointer { cdj_load(e, deck, $0.baseAddress, UInt64(samples.count / 2), rate) })
    }
    private func render(_ e: OpaquePointer, _ frames: Int) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: frames), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in cdj_render(e, lp.baseAddress, rp.baseAddress, UInt32(frames)) } }
        return (l, r)
    }
    private func unity(_ e: OpaquePointer) {
        cdj_crossfader(e, 0); cdj_master(e, 1); cdj_volume(e, 0, 1)
        _ = render(e, 8_000)
    }
    private func tone(_ hz: Double, seconds: Int = 4) -> [Float] {
        (0..<(8_000 * seconds)).flatMap { i -> [Float] in
            let v = Float(sin(Double(i) * 2 * .pi * hz / 8_000) * 0.2); return [v, v]
        }
    }
    private func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)) }

    func testCrossfaderRoutesOppositeStereoDecks() {
        let e = engine(); defer { cdj_destroy(e) }
        let a = (0..<32_000).flatMap { _ in [Float(0.25), Float(0)] }
        let b = (0..<32_000).flatMap { _ in [Float(0), Float(0.25)] }
        load(e, a); load(e, b, deck: 1)
        unity(e); cdj_volume(e, 1, 1); cdj_play(e, 0, true); cdj_play(e, 1, true)
        var out = render(e, 4_000)
        XCTAssertEqual(out.0.last!, 0.25, accuracy: 0.001)
        XCTAssertLessThan(abs(out.1.last!), 0.0001)
        cdj_crossfader(e, 1); _ = render(e, 500); out = render(e, 500)
        XCTAssertLessThan(abs(out.0.last!), 0.0001)
        XCTAssertEqual(out.1.last!, 0.25, accuracy: 0.001)
    }

    func testLoopKeepsPositionInsideBounds() {
        let e = engine(); defer { cdj_destroy(e) }
        load(e, tone(100)); unity(e)
        cdj_loop(e, 0, 0.02, 0.04, true); cdj_play(e, 0, true)
        let audio = render(e, 9_531)
        XCTAssertGreaterThanOrEqual(cdj_position(e, 0), 0.02)
        XCTAssertLessThan(cdj_position(e, 0), 0.04)
        XCTAssertTrue(cdj_is_playing(e, 0)); XCTAssertGreaterThan(rms(audio.0[1_000...]), 0.05)
    }

    func testReverseMovesBackwardsAndReadsDescendingRamp() {
        let e = engine(); defer { cdj_destroy(e) }
        load(e, (0..<16_000).flatMap { i in [Float(i) / 80_000, Float(i) / 80_000] })
        unity(e); cdj_seek(e, 0, 1); cdj_reverse(e, 0, true); cdj_play(e, 0, true)
        let result = render(e, 400)
        XCTAssertGreaterThan(result.0.first!, result.0.last!)
        XCTAssertEqual(cdj_position(e, 0), 0.95, accuracy: 0.0001)
    }

    func testRateChangesSourceTimeWithoutKeylockClaim() {
        let e = engine(); defer { cdj_destroy(e) }
        load(e, tone(120)); unity(e); cdj_rate(e, 0, 2); cdj_play(e, 0, true)
        _ = render(e, 8_000)
        XCTAssertGreaterThan(cdj_position(e, 0), 1.9)
        XCTAssertLessThanOrEqual(cdj_position(e, 0), 2)
    }

    func testEQActuallyAttenuatesLowFrequency() {
        let e = engine(); defer { cdj_destroy(e) }
        load(e, tone(60)); unity(e); cdj_play(e, 0, true)
        let dry = render(e, 8_000).0
        cdj_eq(e, 0, -36, 0, 0)
        let cut = render(e, 8_000).0
        XCTAssertLessThan(rms(cut[2_000...]), rms(dry[2_000...]) * 0.4)
    }

    func testLowPassActuallyRemovesHighFrequency() {
        let e = engine(); defer { cdj_destroy(e) }
        load(e, tone(2_000)); unity(e); cdj_play(e, 0, true)
        let dry = render(e, 8_000).0
        cdj_filter(e, 0, -1)
        let filtered = render(e, 8_000).0
        XCTAssertLessThan(rms(filtered[2_000...]), rms(dry[2_000...]) * 0.1)
    }

    func testEchoProducesDelayedImpulse() {
        let e = engine(); defer { cdj_destroy(e) }
        var impulse = [Float](repeating: 0, count: 32_000)
        impulse[2_000] = 0.3; impulse[2_001] = 0.3
        load(e, impulse); unity(e); cdj_effect(e, 0, 1, 0.8); cdj_play(e, 0, true)
        let out = render(e, 5_000).0
        XCTAssertGreaterThan(abs(out[1_000]), 0.05)
        XCTAssertGreaterThan(abs(out[4_000]), 0.05)
        XCTAssertEqual(out[3_900], 0, accuracy: 0.0001)
    }

    func testPatternAndRecordingRingCaptureExactRenderedAudio() {
        let e = engine(); defer { cdj_destroy(e) }
        cdj_pattern(e, true, 120, 0.5)
        XCTAssertTrue(cdj_record_begin(e))
        let out = render(e, 8_000)
        cdj_record_end(e)
        var stereo = [Float](repeating: 0, count: 16_000)
        let count = stereo.withUnsafeMutableBufferPointer { cdj_record_drain(e, $0.baseAddress, 8_000) }
        XCTAssertEqual(count, 8_000); XCTAssertEqual(cdj_record_dropped(e), 0)
        XCTAssertGreaterThan(rms(out.0[...]), 0.01)
        for i in 0..<8_000 { XCTAssertEqual(stereo[i * 2], out.0[i]); XCTAssertEqual(stereo[i * 2 + 1], out.1[i]) }
    }

    func testAllFourDecksMixFiniteAudioAndReachEnd() {
        let e = engine(); defer { cdj_destroy(e) }
        for deck in 0..<4 { load(e, tone(Double(80 + deck * 35), seconds: 1), deck: Int32(deck)); cdj_play(e, Int32(deck), true) }
        let output = render(e, 10_000)
        XCTAssertTrue(output.0.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertTrue(output.1.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertGreaterThan(rms(output.0[0..<7_000]), 0.01)
        for deck in 0..<4 { XCTAssertFalse(cdj_is_playing(e, Int32(deck))); XCTAssertEqual(cdj_position(e, Int32(deck)), 1, accuracy: 0.0001) }
    }

    func testBufferReplacementAndReclamationDuringRender() {
        let e = engine(); defer { cdj_destroy(e) }
        let pcm = tone(100, seconds: 1)
        load(e, pcm)
        let worker = DispatchQueue(label: "core.test.render")
        let finished = expectation(description: "render completes")
        worker.async {
            for _ in 0..<300 { cdj_play(e, 0, true); _ = self.render(e, 128) }
            finished.fulfill()
        }
        for _ in 0..<100 { load(e, pcm); cdj_reclaim(e) }
        wait(for: [finished], timeout: 5)
        cdj_reclaim(e)
        XCTAssertTrue(cdj_position(e, 0).isFinite)
    }
}
