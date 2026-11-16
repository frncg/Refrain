//
//  LyricsCleaner.swift
//  MusicPlayer
//

import Foundation

/// Removes promo and credit lines that LRCLIB entries often carry over from
/// the sites they were scraped from, e.g. Mojim's "Find more lyrics at" or a
/// NetEase-style "作词 : …" block.
///
/// Built from a sample of ~1,150 LRCLIB entries. Real lyrics often contain
/// words like "follow", "lyrics", "sync" or "Instagram", even on the first or
/// last line, so matching is deliberately narrow:
/// - Ads (known ad phrases, ad sites, URLs) are removed anywhere.
/// - Credits ("Composer: …", "Synced by …") are removed only as a block at the
///   very start or end of the song.
enum LyricsCleaner {
    /// Indices of `lines` to keep, in order.
    static func keptIndices(of lines: [String]) -> [Int] {
        var removed = Set(lines.indices.filter { isAd(lines[$0]) })

        // Credit blocks at either end, skipping blank lines and ads.
        for order in [Array(lines.indices), Array(lines.indices.reversed())] {
            for index in order {
                let text = lines[index].trimmingCharacters(in: .whitespaces)
                if removed.contains(index) || text.isEmpty { continue }
                guard isCredit(text) else { break }
                removed.insert(index)
            }
        }

        return lines.indices.filter { !removed.contains($0) }
    }

    /// Plain (unsynced) lyrics with the same lines removed; blank lines stay.
    static func clean(plain: String) -> String {
        let lines = plain.components(separatedBy: .newlines)
        return keptIndices(of: lines).map { lines[$0] }.joined(separator: "\n")
    }

    static func isAd(_ text: String) -> Bool {
        matches(adPattern, text)
    }

    static func isCredit(_ text: String) -> Bool {
        matches(creditPattern, text)
    }

    // MARK: - Patterns

    private static let adPattern = regex(
        // Links.
        #"https?://|www\.|\b[a-z0-9-]+\.(com|net|org|cn|tw|hk|jp|kr|ru|io|co|me|tv)\b"#,
        // Ad phrases. Mojim's watermark loses its domain in some entries.
        #"find more lyrics|more lyrics at|lyrics (are )?(provided|powered|brought to you) by"#,
        #"轉載來自|转载来自|魔鏡歌詞網|魔镜歌词网|更多更詳盡歌詞|更多更详尽歌词"#,
        // Lyric and subtitle sites, by name.
        #"\b(rentanadviser|megalobiz|lyricsify|musixmatch|azlyrics|lyricsfreak|amara\.org)\b"#
    )

    private static let creditPattern = regex(
        // A role label followed by a colon, as in "作词 : 周杰伦" or "Producer: X".
        #"^(作词|作詞|作曲|编曲|編曲|词|詞|曲|制作人|製作人|制作|製作|监制|監製|出品|发行|發行|混音|母带|录音|錄音|和声|和聲|吉他|贝斯|鼓|键盘|弦乐|配唱|统筹|企划|op|sp|lyrics|lyricist|written by|composer|composed by|music by|producer|produced by|arranger|arranged by|mixed by|mastered by|vocals?|guitar|bass|drums|keys|strings)\s*[:：]"#,
        // "Synced by …", "LRC by …", "Subtitles by …".
        #"\b(lyrics|lrc|subtitles?|captions?|sync(ed)?|timings?|transcri(bed|ption)|edited|translated|translation)\s+(made\s+)?by\b"#
    )

    private static func regex(_ alternatives: String...) -> NSRegularExpression {
        try! NSRegularExpression(pattern: alternatives.joined(separator: "|"), options: [.caseInsensitive])
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
