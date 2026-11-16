import Testing
@testable import Refrain

struct LRCParserTests {

    @Test func parsesTimestampsAndSkipsMetadata() {
        let lines = LRCParser.parse("""
        [ar:Daft Punk]
        [00:30.64] Like the legend of the phoenix, huh
        [01:05.10]
        [00:35.11] Our ends were beginnings
        """)

        #expect(lines.map(\.text) == ["Like the legend of the phoenix, huh", "Our ends were beginnings", ""])
        #expect(lines.map(\.time) == [30.64, 35.11, 65.10])
        #expect(lines.map(\.id) == [0, 1, 2])
    }

    @Test func expandsLinesWithMultipleTimestamps() {
        let lines = LRCParser.parse("[00:10.00][00:20.00] Chorus")

        #expect(lines.map(\.time) == [10, 20])
        #expect(lines.allSatisfy { $0.text == "Chorus" })
    }

    @Test func activeIndexLeadsElapsedTimeByHalfASecond() {
        let lines = LRCParser.parse("""
        [00:02.00] One
        [00:06.00] Two
        """)

        #expect(LRCParser.activeIndex(in: lines, at: 1.4) == nil)
        #expect(LRCParser.activeIndex(in: lines, at: 1.5) == 0)
        #expect(LRCParser.activeIndex(in: lines, at: 5.4) == 0)
        #expect(LRCParser.activeIndex(in: lines, at: 5.5) == 1)
        #expect(LRCParser.activeIndex(in: lines, at: 100) == 1)
    }
}
