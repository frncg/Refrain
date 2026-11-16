import AudioToolbox
import CoreAudio
import Foundation
import os

/// Removes the vocals from the playing app, like Apple Music Sing: its audio is
/// tapped (muted) and replayed through `VocalRemover`, about 0.13s late (`delay`).
@MainActor @Observable
final class Karaoke {
    static let shared = Karaoke()

    private(set) var isOn = false

    var delay: TimeInterval { isOn ? latency : 0 }

    private var latency: TimeInterval = 0
    @ObservationIgnored private var engine: KaraokeEngine?
    @ObservationIgnored private var source: String?

    private init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                self.start(source: source)
            }
        }
    }

    func toggle(source: String?) {
        if isOn {
            stop()
        } else if let source {
            start(source: source)
        }
    }

    /// Moves to a new playing app, or stops when the source isn't music (nil).
    func follow(source: String?) {
        guard isOn, source != self.source else { return }
        if let source {
            start(source: source)
        } else {
            stop()
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        source = nil
        isOn = false
    }

    private func start(source: String) {
        stop()
        guard SystemAudioPermission.status == .authorized else { return }
        let engine = KaraokeEngine()
        do {
            try engine.start(processes: KaraokeEngine.audioProcesses(of: source))
        } catch {
            engine.stop()
            Logger().error("Karaoke failed to start for \(source): \(error)")
            return
        }
        self.engine = engine
        self.source = source
        latency = engine.latency
        isOn = true
    }
}

enum KaraokeError: Error {
    case noAudioProcess
    case noSoundIsolation
}

private final class KaraokeEngine: @unchecked Sendable {
    private(set) var latency: TimeInterval = 0

    private let queue = DispatchQueue(label: "Karaoke", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var remover: VocalRemover?

    deinit { stop() }

    func start(processes: [AudioObjectID]) throws {
        guard !processes.isEmpty else { throw KaraokeError.noAudioProcess }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .muted
        try checkAudio(AudioHardwareCreateProcessTap(description, &tapID))
        aggregateID = try makeTapAggregateDevice(name: "Refrain Karaoke", tap: description.uuid)

        let sampleRate: Float64 = try audioProperty(aggregateID, kAudioDevicePropertyNominalSampleRate)
        let remover = try VocalRemover(sampleRate: sampleRate)
        self.remover = remover
        latency = remover.latency
        try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            remover.process(input, into: output)
        })
        try checkAudio(AudioDeviceStart(aggregateID, procID))
    }

    /// Destroying the tap unmutes the app.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        remover = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The app's audio processes, its helpers (e.g. `com.google.Chrome.helper`), and WebKit's GPU process for Safari.
    static func audioProcesses(of bundleIdentifier: String) throws -> [AudioObjectID] {
        let app = bundleIdentifier.lowercased()
        let isSafari = app.hasPrefix("com.apple.safari")
        return try processObjects().filter { process in
            guard let identifier: CFString = try? audioProperty(process, kAudioProcessPropertyBundleID) else { return false }
            let bundle = (identifier as String).lowercased()
            return bundle == app || bundle.hasPrefix(app + ".") || (isSafari && bundle == "com.apple.webkit.gpu")
        }
    }

    private static func processObjects() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try checkAudio(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes))
        return processes
    }
}
