import Testing
@testable import Refrain

struct LyricsCleanerTests {

    @Test func removesAdsAnywhere() {
        let lines = LRCParser.parse("""
        [00:01.00] First line
        [00:02.00] Find more lyrics at
        [00:03.00] Middle line
        [00:04.00] 轉載來自 魔鏡歌詞網
        [00:05.00] Visit www.example.com for more
        [00:06.00] Last line
        """)

        #expect(lines.map(\.text) == ["First line", "Middle line", "Last line"])
        // IDs must equal positions.
        #expect(lines.map(\.id) == [0, 1, 2])
    }

    @Test func removesCreditBlocksAtTheEdges() {
        let lines = LRCParser.parse("""
        [00:00.00] 作词 : 米津玄師
        [00:00.50] 作曲 : 米津玄師
        [00:01.00] 编曲 : 米津玄師/室屋光一郎
        [00:02.00] 夢ならばどれほどよかったでしょう
        [00:03.00] 未だにあなたのことを夢にみる
        [00:04.00]
        [00:05.00] Synced by someone
        """)

        #expect(lines.map(\.text) == ["夢ならばどれほどよかったでしょう", "未だにあなたのことを夢にみる", ""])
    }

    @Test func keepsCreditLookalikesInsideTheSong() {
        let lines = LRCParser.parse("""
        [00:01.00] Real first line
        [00:02.00] Producer: this one is a lyric here
        [00:03.00] Real last line
        """)

        #expect(lines.count == 3)
    }

    @Test func keepsRealLyricsThatLookPromotional() {
        for lyric in [
            "Darling, just dive right in and follow my lead",
            "Hey, Instagram",
            "Behold these lyrics",
            "While the stars sync with my heart beat",
            "太丰富的编曲",
            "A jedna šestka hraje aj dnes keď sa vozíme mojim jegom",
            "And she said:",
        ] {
            #expect(!LyricsCleaner.isAd(lyric), "\(lyric)")
            #expect(!LyricsCleaner.isCredit(lyric), "\(lyric)")
        }
    }

    @Test func cleansPlainLyrics() {
        let plain = "作词 : Someone\nFirst verse\n\nSecond verse\nFind more lyrics at"
        #expect(LyricsCleaner.clean(plain: plain) == "First verse\n\nSecond verse")
    }
}
