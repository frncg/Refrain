import SwiftUI

struct LyricsStyle {
    var lineSize: CGFloat = 42
    var lineSpacing: CGFloat = 24
    /// Lets the first and last lines scroll to the active position.
    var edgePadding: CGFloat = 300
    var plainSize: CGFloat = 22
    var plainPadding: CGFloat = 40
    var messageFont: Font = .title2.bold()

    static let lockScreen = LyricsStyle()
    static let menuBar = LyricsStyle(lineSize: 17, lineSpacing: 10, edgePadding: 120, plainSize: 13, plainPadding: 16, messageFont: .headline)
}

struct LyricsColumn: View {
    let music: MusicController
    var style = LyricsStyle.lockScreen

    @Environment(\.playerTint) private var tint
    private let karaoke = Karaoke.shared

    var body: some View {
        ZStack {
            content
                .id(music.lyricsID)
                .transition(.opacity)
        }
        .highFrameRate()
    }

    @ViewBuilder
    private var content: some View {
        switch music.lyrics {
        case .synced(let lines):
            SyncedLyricsView(
                lines: lines,
                // Karaoke audio trails the original.
                activeIndex: LRCParser.activeIndex(in: lines, at: music.elapsed - karaoke.delay),
                style: style,
                onSeek: music.seek
            )
        case .plain(let text):
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(.system(size: style.plainSize, weight: .bold))
                    .foregroundStyle(tint.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, style.plainPadding)
            }
        case .loading:
            ProgressView()
        case .instrumental:
            message("Instrumental")
        case .notFound:
            message("No lyrics found")
        case .failed:
            message("Couldn't load lyrics")
        case .idle:
            // Not EmptyView, which would collapse the column.
            Color.clear
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(style.messageFont)
            .foregroundStyle(tint.opacity(0.4))
    }
}

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    let style: LyricsStyle
    var onSeek: (TimeInterval) -> Void

    @Environment(\.playerTint) private var tint
    @State private var hoveredID: Int?

    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.3)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: style.lineSpacing) {
                    ForEach(lines) { line in
                        let isActive = line.id == activeIndex
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: style.lineSize, weight: .bold))
                            .foregroundStyle(tint.opacity(isActive || line.id == hoveredID ? 1 : 0.3))
                            .scaleEffect(isActive ? 1 : 0.8, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(line.time) }
                            .onHover { hovering in
                                if hovering {
                                    hoveredID = line.id
                                } else if hoveredID == line.id {
                                    hoveredID = nil
                                }
                            }
                            .id(line.id)
                    }
                }
                .animation(.interpolatingSpring(.smooth), value: activeIndex)
                .animation(.easeOut(duration: 0.15), value: hoveredID)
                .padding(.vertical, style.edgePadding)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.15),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .onAppear {
                proxy.scrollTo(activeIndex ?? 0, anchor: Self.activeLineAnchor)
            }
            .onChange(of: activeIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(newIndex ?? 0, anchor: Self.activeLineAnchor)
                }
            }
            .onChange(of: lines) {
                proxy.scrollTo(activeIndex ?? 0, anchor: Self.activeLineAnchor)
            }
        }
    }
}
