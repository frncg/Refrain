import Testing
@testable import Refrain

struct LyricsLagAnimationTests {
    @Test func startsAtFullDistanceAndRests() {
        #expect(LyricsLagAnimation.remaining(at: 0, along: 0.5) == 1)
        #expect(LyricsLagAnimation.remaining(at: 3, along: 0) == nil)
        #expect(LyricsLagAnimation.remaining(at: 3, along: 1) == nil)
    }

    @Test func linesFurtherAlongTrail() throws {
        for time in [0.1, 0.2, 0.3] {
            let first = try #require(LyricsLagAnimation.remaining(at: time, along: 0))
            let last = try #require(LyricsLagAnimation.remaining(at: time, along: 1))
            #expect(last > first)
        }
    }
}
