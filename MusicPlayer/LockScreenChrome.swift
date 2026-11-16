//
//  LockScreenChrome.swift
//  MusicPlayer
//

import SwiftUI
import OpenDirectory

/// Full-screen lock screen: blurred artwork, a redrawn date/clock/login hint,
/// and the player in the band between them. While the miniplayer is showing,
/// only it is drawn, so the real lock screen shows around it.
///
/// loginwindow draws the wallpaper, clock and login UI in one opaque window, so
/// nothing can go between them. Instead this covers all of it and redraws the
/// non-interactive parts. The password field is never redrawn: the overlay
/// collapses to the miniplayer when the user starts typing (see
/// `LockScreenController`).
struct LockScreenOverlay: View {
    let music: MusicController
    @Bindable var state = LockScreenOverlayState()
    var onExit: () -> Void

    @AppStorage(LockScreenOverlayState.expandedKey) private var savedExpanded = true

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                // Faded with the same animation that collapses the player, and
                // removed rather than hidden while collapsed, so the full-screen
                // blur isn't kept rendering (it pulses many times a second).
                if state.expanded {
                    Group {
                        BlurredArtworkBackground(music: music)
                        LockScreenChrome(size: geometry.size)
                    }
                    .transition(.opacity)
                }

                // Saves only the user's own choices (artwork tap, miniplayer tap, lyrics toggle),
                // not the collapse while typing a password.
                NowPlayingView(music: music, expanded: Binding {
                    state.expanded
                } set: {
                    state.expanded = $0
                    savedExpanded = $0
                }, onExit: onExit)
                    .frame(width: min(geometry.size.width - 160, 1000))
                    .frame(maxHeight: .infinity)
                    .padding(.top, height * 0.30)
                    .padding(.bottom, height * 0.22)
            }
            // Full screen even while collapsed, when the background is gone,
            // so the player stays centred.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Whether the overlay shows the full player or the miniplayer. Shared with
/// `LockScreenController` so typing can collapse it.
@Observable
final class LockScreenOverlayState {
    /// UserDefaults key for the layout the user last chose. Each lock starts in it.
    static let expandedKey = "lockScreenExpanded"

    var expanded = UserDefaults.standard.object(forKey: expandedKey) as? Bool ?? true
}

/// The date, clock and login hint, matched to the real lock screen by measuring
/// screenshots of both on a 1800×1169pt display; sizes and positions scale
/// with screen height.
private struct LockScreenChrome: View {
    let size: CGSize

    private var scale: CGFloat { size.height / 1169 }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ZStack {
                // Kept out of the shadowed group below, which renders as its
                // own layer, so they blend with the artwork, not transparency.
                Vibrant {
                    Text(Self.timeFormatter.string(from: context.date))
                        .font(ClockFont.font(size: 164.3 * scale))
                        .contentTransition(.numericText())
                }
                .position(x: size.width / 2, y: size.height * 0.188)

                Vibrant {
                    Text(Self.dateFormatter.string(from: context.date))
                        .font(.system(size: 33 * scale, weight: .medium))
                }
                .position(x: size.width / 2, y: size.height * 0.107)

                ZStack {
                    avatar
                        .frame(width: 56 * scale, height: 56 * scale)
                        .position(x: size.width / 2, y: size.height * 0.864)

                    Text(UserProfile.fullName)
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .position(x: size.width / 2, y: size.height * 0.9098)

                    Text("Touch ID or Enter Password")
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.64))
                        .position(x: size.width / 2, y: size.height * 0.9361)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 4)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let picture = UserProfile.picture {
            Image(nsImage: picture)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// "Wed Oct 28", like the system's, without the comma a template adds.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    /// "11:47" or "23:47" depending on the 24-hour setting, never with AM/PM.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        let uses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
        formatter.dateFormat = uses12Hour ? "h:mm" : "HH:mm"
        return formatter
    }()
}

/// Frosted, vibrant text like the system lock screen's clock: filled with a
/// light material of the artwork behind it, then brightened with plus-lighter
/// so it picks up the artwork's colour while staying readable. Chosen over
/// plus-lighter alone (flat white on bright artwork) and over the dark
/// materials, which grey the text out.
private struct Vibrant<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            content()
                .foregroundStyle(.thinMaterial)
            content()
                .foregroundStyle(.white.opacity(0.25))
                .blendMode(.plusLighter)
        }
        // The light materials are the bright, frosted ones.
        .environment(\.colorScheme, .light)
    }
}

/// The lock screen's own clock face: SF Soft Numeric, one of the private
/// numeric fonts in ADTNumeric.ttc (it only covers digits and separators).
/// It's a variable font; the weight was fitted to the real clock's colon dots.
private enum ClockFont {
    private static let weightAxis = 0x77676874 // 'wght'
    private static let widthAxis = 0x77647468  // 'wdth'

    private static let descriptor: CTFontDescriptor? = {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc")
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        guard let base = descriptors.first(where: {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == ".SFSoftNumeric-Regular"
        }) else {
            return nil
        }
        let weighted = CTFontDescriptorCreateCopyWithVariation(base, weightAxis as CFNumber, 450)
        return CTFontDescriptorCreateCopyWithVariation(weighted, widthAxis as CFNumber, 99.5)
    }()

    static func font(size: CGFloat) -> Font {
        guard let descriptor else { return .system(size: size, weight: .medium) }
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}

private enum UserProfile {
    static let fullName = NSFullUserName()

    /// The account picture shown on the login screen.
    static let picture: NSImage? = {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(
                  withRecordType: kODRecordTypeUsers,
                  name: NSUserName(),
                  attributes: [kODAttributeTypeJPEGPhoto]
              ),
              let data = (try? record.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data
        else {
            return nil
        }
        // Shown at 56pt; account pictures are often much larger.
        return ImageDownsampling.image(data, maxPixelSize: 168)
    }()
}

#if DEBUG
#Preview("Live", traits: .fixedLayout(width: 1800, height: 1169)) {
    @Previewable @State var music = MusicController.live()
    LockScreenOverlay(music: music, onExit: {})
}

// Sample artwork, for checking how the clock's vibrancy picks up colour.
#Preview("Sample", traits: .fixedLayout(width: 1800, height: 1169)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @State var state: LockScreenOverlayState = {
        let state = LockScreenOverlayState()
        state.expanded = true
        return state
    }()
    LockScreenOverlay(music: music, state: state, onExit: {})
}

// Only the miniplayer is drawn; on the lock screen the real one shows around it.
#Preview("Collapsed", traits: .fixedLayout(width: 1800, height: 1169)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @State var state: LockScreenOverlayState = {
        let state = LockScreenOverlayState()
        state.expanded = false
        return state
    }()
    LockScreenOverlay(music: music, state: state, onExit: {})
        .background(.black)
}
#endif
