import CoreAudio
import Foundation
import os

/// Live loudness of system output in five bands (bass first), and a pulse on each
/// drum hit. Captured with a process tap, since Now Playing doesn't expose audio.
@MainActor @Observable
final class SystemAudioLevels {
    static let shared = SystemAudioLevels()
    nonisolated static let bandCount = 5

    private(set) var levels = [Float](repeating: 0, count: bandCount)
    private(set) var pulse: Float = 0

    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var clients = 0

    private init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.tap != nil else { return }
                self.stopTap()
                self.startTap()
            }
        }
    }

    func requestPermission() {
        guard SystemAudioPermission.status == .unknown else { return }
        SystemAudioPermission.request { [weak self] granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, granted, self.clients > 0 else { return }
                    self.startTap()
                }
            }
        }
    }

    /// Reference counted; balance with `stop()`.
    func start() {
        clients += 1
        if clients == 1 { startTap() }
    }

    func stop() {
        clients = max(clients - 1, 0)
        if clients == 0 { stopTap() }
    }

    private func startTap() {
        // Never prompts here: a prompt raised on the lock screen would be hidden.
        guard tap == nil, SystemAudioPermission.status == .authorized else { return }
        let tap = SystemAudioTap { [weak self] output in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.levels = output.levels
                    self.pulse = output.pulse
                }
            }
        }
        do {
            try tap.start()
            self.tap = tap
        } catch {
            Logger().error("System audio tap failed: \(error)")
        }
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        levels = [Float](repeating: 0, count: Self.bandCount)
        pulse = 0
    }
}

private final class SystemAudioTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SystemAudioTap", qos: .userInteractive)
    private let onOutput: @Sendable (SpectrumAnalyzer.Output) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(onOutput: @escaping @Sendable (SpectrumAnalyzer.Output) -> Void) {
        self.onOutput = onOutput
    }

    deinit { stop() }

    func start() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        try checkAudio(AudioHardwareCreateProcessTap(description, &tapID))

        let format: AudioStreamBasicDescription = try audioProperty(tapID, kAudioTapPropertyFormat)
        aggregateID = try makeTapAggregateDevice(name: "Refrain Levels", tap: description.uuid)

        let analyzer = SpectrumAnalyzer(
            sampleRate: format.mSampleRate,
            channels: Int(max(format.mChannelsPerFrame, 1)),
            onOutput: onOutput
        )
        try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            analyzer.process(input)
        })
        try checkAudio(AudioDeviceStart(aggregateID, procID))
    }

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
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
