import SwiftUI
import OpenDirectory

/// The date, clock and login hint, measured against the real lock screen on a
/// 1800×1169pt display and scaled with screen height.
struct LockScreenChrome: View {
    let size: CGSize
    var user = LockScreenUser.current

    private var scale: CGFloat { size.height / 1169 }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ZStack {
                // Outside the shadowed group, so they blend with the artwork.
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

                    Text(user.name)
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
        if let picture = user.picture {
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    /// 12- or 24-hour per the user's setting, never with AM/PM.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        let uses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
        formatter.dateFormat = uses12Hour ? "h:mm" : "HH:mm"
        return formatter
    }()
}

/// Frosted text like the system clock: a light material plus a plus-lighter white copy.
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
        .environment(\.colorScheme, .light)
    }
}

/// The lock screen clock's private variable font, SF Soft Numeric.
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

struct LockScreenUser {
    var name: String
    var picture: NSImage?

    static let current = LockScreenUser(name: NSFullUserName(), picture: accountPicture)

    private static var accountPicture: NSImage? {
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
        return ImageDownsampling.image(data, maxPixelSize: 168)
    }
}
