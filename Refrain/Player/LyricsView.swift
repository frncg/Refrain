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

    func scaled(by scale: CGFloat) -> LyricsStyle {
        var style = self
        style.lineSize *= scale
        style.lineSpacing *= scale
        style.edgePadding *= scale
        style.plainSize *= scale
        style.plainPadding *= scale
        return style
    }
    static let vertical = LyricsStyle(lineSize: 30, lineSpacing: 18, edgePadding: 240, plainSize: 20, plainPadding: 24, messageFont: .title3.bold())
    static let menuBar = LyricsStyle(lineSize: 17, lineSpacing: 10, edgePadding: 120, plainSize: 13, plainPadding: 16, messageFont: .headline)
}

extension EnvironmentValues {
    /// Set by the player window while the user drags its edge.
    @Entry var isLiveResizing = false
}

struct LyricsColumn: View {
    let music: MusicController
    var style = LyricsStyle.lockScreen
    /// Where the active line's centre sits, as a share of the column's height; nil puts it near the top.
    var focus: CGFloat? = nil

    @Environment(\.playerTint) private var tint
    @Environment(\.isLiveResizing) private var isLiveResizing
    private let karaoke = Karaoke.shared

    var body: some View {
        ZStack {
            content
                .id(music.lyricsID)
                // Synced lines stagger in on their own.
                .transition(isSynced ? .asymmetric(insertion: .identity, removal: .opacity) : .opacity)
        }
        .highFrameRate()
        // Hidden while the window resizes, as the lines rewrap and scroll; it fades back in once the
        // active line is back in place.
        .animation(isLiveResizing ? nil : .easeOut(duration: 0.6)) { $0.opacity(isLiveResizing ? 0 : 1) }
    }

    private var isSynced: Bool {
        if case .synced = music.lyrics { true } else { false }
    }

    @ViewBuilder
    private var content: some View {
        switch music.lyrics {
        case .synced(let lines):
            // Karaoke audio trails the original.
            let activeIndex = LRCParser.activeIndex(in: lines, at: music.elapsed - karaoke.delay)
            SyncedLyricsView(
                lines: lines,
                activeIndex: activeIndex,
                // While scrubbing, the lyrics scroll with the bar but the highlight waits for the seek.
                scrollIndex: music.scrubTime.map { LRCParser.activeIndex(in: lines, at: $0) } ?? activeIndex,
                style: style,
                focus: focus,
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
    let scrollIndex: Int?
    let style: LyricsStyle
    let focus: CGFloat?
    var onSeek: (TimeInterval) -> Void

    @Environment(\.playerTint) private var tint
    @Environment(\.isLiveResizing) private var isLiveResizing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: Int?
    @State private var revealed = false
    @State private var position = ScrollPosition(idType: Int.self)
    /// How far lines are drawn from their place after an automatic scroll, before they spring back.
    @State private var lag: CGFloat = 0
    @State private var followsDown = true
    @State private var layout = SyncedLyricsLayout()

    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.3)
    private static let coordinateSpace = "lyrics"
    private static let revealStep = 0.05
    /// Lines visible above the active one, which start the stagger.
    private static let revealLinesAbove = 3
    private static let revealMaxSteps = 12

    /// Staggers from the top of the visible lines; lines further down share the last delay.
    private func revealDelay(for id: Int) -> Double {
        let rank = id - (activeIndex ?? 0) + Self.revealLinesAbove
        return Double(min(max(rank, 0), Self.revealMaxSteps)) * Self.revealStep
    }

    /// Incoming lines settle last: lower lines when scrolling down, higher ones when scrolling up.
    private func lagAnimation(for id: Int) -> Animation {
        guard let frame = layout.lines[id], let height = layout.scroll?.containerSize.height, height > 0 else {
            return Animation(LyricsLagAnimation(along: 0))
        }
        let along = (frame.midY - layout.target) / height
        return Animation(LyricsLagAnimation(along: followsDown ? along : 1 - along))
    }

    private var anchor: UnitPoint {
        layout.focus.map { UnitPoint(x: 0.5, y: $0) } ?? Self.activeLineAnchor
    }

    /// The scroll offset that puts a line at the anchor (its centre at `focus`, when set).
    private func target(for id: Int) -> CGFloat? {
        guard let line = layout.lines[id], let geometry = layout.scroll else { return nil }
        let height = geometry.containerSize.height
        let lowest = -geometry.contentInsets.top
        let highest = max(lowest, geometry.contentSize.height - height + geometry.contentInsets.bottom)
        let offset = layout.focus.map { line.midY - height * $0 }
            ?? line.minY + (line.height - height) * Self.activeLineAnchor.y
        return min(max(offset, lowest), highest)
    }

    private func jump(to id: Int) {
        guard let target = target(for: id) else {
            position.scrollTo(id: id, anchor: anchor)
            return
        }
        position.scrollTo(y: target)
    }

    private func scroll(to id: Int) {
        guard let target = target(for: id), let geometry = layout.scroll else {
            position.scrollTo(id: id, anchor: anchor)
            return
        }
        let height = geometry.containerSize.height
        let delta = target - geometry.contentOffset.y
        guard delta != 0 else { return }
        if reduceMotion || abs(delta) > height {
            withAnimation(.easeInOut(duration: 0.5)) { position.scrollTo(y: target) }
            return
        }
        // Moves the lines back to where they were, unanimated, then lets each spring into place.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            followsDown = delta > 0
            layout.target = target
            lag += delta
            position.scrollTo(y: target)
        }
        DispatchQueue.main.async { lag = 0 }
    }

    var body: some View {
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
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : style.lineSpacing)
                        .animation(.smooth(duration: 0.5).delay(revealDelay(for: line.id)), value: revealed)
                        .offset(y: lag)
                        .animation(lagAnimation(for: line.id), value: lag)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.coordinateSpace))
                        } action: { frame in
                            layout.lines[line.id] = frame
                        }
                        .id(line.id)
                }
            }
            .animation(.interpolatingSpring(.smooth), value: activeIndex)
            .animation(.easeOut(duration: 0.15), value: hoveredID)
            .padding(.vertical, style.edgePadding)
            .coordinateSpace(.named(Self.coordinateSpace))
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            layout.scroll = geometry
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
            layout.focus = focus
            position.scrollTo(id: scrollIndex ?? 0, anchor: anchor)
            revealed = true
            // The anchor only centres a line exactly once it has been measured.
            DispatchQueue.main.async { jump(to: scrollIndex ?? 0) }
        }
        .onChange(of: scrollIndex) { _, newIndex in
            scroll(to: newIndex ?? 0)
        }
        .onChange(of: focus) { _, focus in
            layout.focus = focus
            jump(to: scrollIndex ?? 0)
        }
        .onChange(of: isLiveResizing) { _, resizing in
            if !resizing { jump(to: scrollIndex ?? 0) }
        }
        .onChange(of: lines) {
            jump(to: scrollIndex ?? 0)
        }
    }
}

/// Measurements read when a line changes, kept out of view state so scrolling doesn't redraw.
private final class SyncedLyricsLayout {
    var lines: [Int: CGRect] = [:]
    var scroll: ScrollGeometry?
    /// Where the last automatic scroll went.
    var target: CGFloat = 0
    /// Kept here so a deferred scroll sees the current focus rather than the one it captured.
    var focus: CGFloat?
}
