import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum Lyrics: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    case failed

    var hasText: Bool {
        switch self {
        case .synced, .plain: true
        default: false
        }
    }

    /// Whether the track has lyrics to show, or nil while that isn't known yet.
    var availability: Bool? {
        switch self {
        case .synced, .plain: true
        case .notFound, .failed, .instrumental: false
        case .idle, .loading: nil
        }
    }
}

enum LRCParser {
    /// Parses lines like `[01:23.45] text`, with any number of timestamps. Other tags are skipped.
    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(time: TimeInterval, text: String)] = []

        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var times: [TimeInterval] = []

            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTimestamp(tag) {
                    times.append(time)
                }
                rest = rest[rest.index(after: close)...]
            }

            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                entries.append((time, text))
            }
        }

        let sorted = entries.sorted { $0.time < $1.time }
        // IDs are assigned after cleaning, so they equal positions (see `activeIndex`).
        return LyricsCleaner.keptIndices(of: sorted.map(\.text))
            .enumerated()
            .map { LyricLine(id: $0.offset, time: sorted[$0.element].time, text: sorted[$0.element].text) }
    }

    /// How far ahead of the vocal a line is highlighted.
    static let lead: TimeInterval = 0.5

    static func activeIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        lines.lastIndex { $0.time <= time + lead }
    }

    private static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1])
        else {
            return nil
        }
        return minutes * 60 + seconds
    }
}
