//
//  NowPlayingSource.swift
//  MusicPlayer
//

import Foundation

/// Decides whether a now playing session is music, so the lock screen only
/// takes over for music apps and music websites, not videos, podcasts or calls.
///
/// Browsers report only their own bundle identifier, never the page, so for a
/// browser this asks it (over AppleScript) for its open tabs and looks for one
/// on a music site whose title contains the playing track's title. That needs
/// the user's one-time Automation permission for that browser; without it, or
/// for browsers that can't list tabs (Firefox), the source counts as not music.
enum NowPlayingSource {
    /// Music players, by bundle identifier. Add others here.
    static let musicApps: Set<String> = [
        "com.apple.Music",
        "com.apple.iTunes",
        "com.spotify.client",
        "rocks.spotifast.Spotifast",
        "com.tidal.desktop",
        "com.amazon.music",
        "com.deezer.deezer-desktop",
        "com.github.th-ch.youtube-music",
        "com.coppertino.Vox",
        "co.brushedtype.doppler-macos",
        "com.swinsian.Swinsian",
    ]

    /// Music sites, matched against a tab's host and its subdomains.
    static let musicHosts: [String] = [
        "music.apple.com",
        "open.spotify.com",
        "music.youtube.com",
        "soundcloud.com",
        "tidal.com",
        "deezer.com",
        "music.amazon.com",
        "bandcamp.com",
        "pandora.com",
        "qobuz.com",
        "audiomack.com",
        "mixcloud.com",
    ]

    private enum Scripting {
        /// Tabs have `URL` and `name`.
        case safari
        /// Tabs have `URL` and `title`.
        case chromium
    }

    private static let browsers: [String: Scripting] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
    ]

    static func isMusic(bundleIdentifier: String?, title: String?) async -> Bool {
        guard let bundleIdentifier else { return false }
        if musicApps.contains(bundleIdentifier) { return true }

        guard let scripting = browsers[bundleIdentifier], let title, !title.isEmpty else { return false }
        let tabs = await openTabs(bundleIdentifier: bundleIdentifier, scripting: scripting)
        return tabs.contains { tab in
            isMusicHost(tab.url) && tab.title.localizedStandardContains(title)
        }
    }

    static func isMusicHost(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return musicHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Browser tabs

    private struct Tab {
        let url: URL?
        let title: String
    }

    /// Every tab's URL and title, or none if the browser refuses (no permission).
    private static func openTabs(bundleIdentifier: String, scripting: Scripting) async -> [Tab] {
        let titleProperty = scripting == .safari ? "name" : "title"
        // Only ever sent to the browser that is playing, so it is already
        // running and `tell` won't launch it.
        let script = """
        set out to ""
        tell application id "\(bundleIdentifier)"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set out to out & (URL of t) & tab & (\(titleProperty) of t) & linefeed
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
        guard let output = await runAppleScript(script) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Tab(url: URL(string: String(parts[0])), title: String(parts[1]))
        }
    }

    /// Runs the script with `osascript`; nil on failure, e.g. permission denied.
    private static func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
