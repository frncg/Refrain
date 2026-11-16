//
//  SystemAudioLevels.swift
//  MusicPlayer
//

import Accelerate
import CoreAudio
import Foundation
import os

/// Live loudness of what the Mac is playing, in five bands from bass to treble,
/// for the miniplayer's waveform. The Now Playing session doesn't expose audio,
/// so this captures system output with a Core Audio process tap. That needs the
/// "System Audio Recording" permission, asked for at launch (`requestPermission`)
/// because a prompt raised while locked would be hidden behind the lock screen.
@MainActor @Observable
final class SystemAudioLevels {
    static let shared = SystemAudioLevels()
    nonisolated static let bandCount = 5

    /// 0...1 per band, bass first.
    private(set) var levels = [Float](repeating: 0, count: bandCount)
    /// 0...1: jumps on each drum hit and fades out between them.
    private(set) var pulse: Float = 0

    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var clients = 0

    private init() {
        // The tap's aggregate device is clocked by the output device, so follow
        // switches to headphones and back.
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

    /// Starts capturing for one more view; balance with `stop()`.
    func start() {
        clients += 1
        if clients == 1 { startTap() }
    }

    func stop() {
        clients = max(clients - 1, 0)
        if clients == 0 { stopTap() }
    }

    private func startTap() {
        // Never prompts from here, see the type's comment.
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

// MARK: - Tap

/// A private, global, mono tap of everything playing, read through a private
/// aggregate device. Audio arrives on `queue`, never the main thread.
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
        aggregateID = try makeTapAggregateDevice(name: "MusicPlayer Levels", tap: description.uuid)

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

// MARK: - Core Audio helpers

/// A global property of a Core Audio object.
func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value))
    return value.move()
}

func checkAudio(_ status: OSStatus) throws {
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

/// A private aggregate device that reads the process tap `tap`. It's clocked
/// by the default output device, and can also play to it.
func makeTapAggregateDevice(name: String, tap: UUID) throws -> AudioObjectID {
    let outputID: AudioObjectID = try audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    let outputUID: CFString = try audioProperty(outputID, kAudioDevicePropertyDeviceUID)

    let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tap.uuidString,
        ]],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    try checkAudio(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
    return aggregateID
}

// MARK: - Analysis

/// FFTs overlapping 1024-sample windows and turns them into band levels.
/// Each band normalises against its own recent peak, so the bars move across
/// their full height for quiet and loud songs and at any volume.
///
/// It also follows the drums, for a pulse on each hit. A band's hits (onsets)
/// are its rises in loudness from one window to the next. Every half second,
/// the drum bands' last 4s of onsets are autocorrelated over beat-length lags
/// (0.3–1s, 60–200 BPM), and the one whose hits repeat most regularly becomes
/// `rhythmBand`: the kick, or the snare's body when it clearly carries the
/// beat. Treble is never used: hi-hats and cymbals repeat just as regularly,
/// and following them made the pulse jump between songs.
final class SpectrumAnalyzer: @unchecked Sendable {
    struct Output {
        var levels: [Float]
        var pulse: Float
        var rhythmBand: Int
    }

    private static let size = 1024
    private static let hop = 512
    /// Band edges in Hz, log-spaced from bass to treble.
    private static let edges: [Double] = [40, 150, 400, 1000, 3000, 10000]
    /// Below this a band counts as silent rather than quiet.
    private static let silence: Float = -70
    /// How far below a band's recent peak reads as empty, in dB.
    private static let range: Float = 24
    /// How fast a band's peak forgets a loud passage, in dB per window.
    private static let peakDecay: Float = 0.05
    /// How fast a bar falls, in levels per window (it rises instantly).
    private static let fall: Float = 0.05
    /// How fast the pulse fades after a hit, per window: about 0.3s.
    private static let pulseFall: Float = 0.035
    /// Hits weaker than this share of the recent strongest don't pulse.
    private static let pulseThreshold: Float = 0.3
    /// How much more regular another band must be to take over, so the pulse
    /// doesn't hop between bands.
    private static let rhythmHysteresis: Float = 0.1
    /// Bands that can drive the pulse: the kick (40–150 Hz) and the snare's
    /// body (150–400 Hz).
    private static let drumBands = [0, 1]
    /// Added to the kick's score, so the snare takes over only when it's
    /// clearly the steadier beat.
    private static let kickPreference: Float = 0.15

    private let channels: Int
    private let bands: [Range<Int>]
    // Buffers are allocated once: this runs about 94 times a second.
    /// The window being filled; after each analysis its second half moves to
    /// the front, for the next window's 50% overlap.
    private var frame = [Float](repeating: 0, count: size)
    private var frameFill = 0
    private var windowed = [Float](repeating: 0, count: size)
    private var evens = [Float](repeating: 0, count: size / 2)
    private var odds = [Float](repeating: 0, count: size / 2)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var centred: [Float]
    private let historyLength: Int
    private let beatLags: ClosedRange<Int>
    private let windowsPerRhythmCheck: Int
    private let onOutput: @Sendable (Output) -> Void
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)

    private var peaks = [Float](repeating: -50, count: SystemAudioLevels.bandCount)
    private var levels = [Float](repeating: 0, count: SystemAudioLevels.bandCount)
    private var windowCount = 0

    /// Per drum band (`drumBands` order), the last window's level.
    private var previousDecibels = [Float](repeating: silence, count: drumBands.count)
    /// Per drum band, a ring of recent onsets in dB.
    private var onsets: [[Float]]
    private var onsetCursor = 0
    /// Recent strongest hit in the rhythm band, in dB.
    private var onsetPeak: Float = 0
    /// Index into `drumBands` of the band the pulse follows.
    private var rhythmDrum = 0
    private var pulse: Float = 0

    init(sampleRate: Double, channels: Int, onOutput: @escaping @Sendable (Output) -> Void) {
        self.channels = channels
        self.onOutput = onOutput
        let windowsPerSecond = sampleRate / Double(Self.hop)
        historyLength = Int(4 * windowsPerSecond)
        beatLags = Int(0.3 * windowsPerSecond)...Int(1 * windowsPerSecond)
        windowsPerRhythmCheck = Int(0.5 * windowsPerSecond)
        onsets = Array(repeating: Array(repeating: 0, count: historyLength), count: Self.drumBands.count)
        centred = Array(repeating: 0, count: historyLength)
        dft = try! vDSP.DiscreteFourierTransform(
            previous: nil, count: Self.size, direction: .forward, transformType: .complexReal, ofType: Float.self
        )
        let binWidth = sampleRate / Double(Self.size)
        let lastBin = Self.size / 2 - 1
        bands = zip(Self.edges, Self.edges.dropFirst()).map { low, high in
            let start = min(max(Int(low / binWidth), 1), lastBin)
            let end = min(max(Int(high / binWidth), start + 1), lastBin + 1)
            return start..<end
        }
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        process(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    /// Interleaved samples, `channels` per frame.
    func process(_ samples: UnsafeBufferPointer<Float>) {
        // The tap is mono, but take the first channel if it ever isn't.
        for index in stride(from: 0, to: samples.count, by: channels) {
            frame[frameFill] = samples[index]
            frameFill += 1
            if frameFill == Self.size {
                analyze()
                frame.withUnsafeMutableBufferPointer { frame in
                    let start = frame.baseAddress!
                    start.update(from: start + Self.hop, count: Self.size - Self.hop)
                }
                frameFill = Self.size - Self.hop
            }
        }
    }

    private func analyze() {
        vDSP.multiply(frame, window, result: &windowed)
        for index in 0..<(Self.size / 2) {
            evens[index] = windowed[2 * index]
            odds[index] = windowed[2 * index + 1]
        }
        dft.transform(inputReal: evens, inputImaginary: odds, outputReal: &real, outputImaginary: &imaginary)
        // Scaled so a full-scale sine reads about 1.
        let scale = Float(Self.size / 2)

        for (index, bins) in bands.enumerated() {
            var power: Float = 0
            for bin in bins {
                power += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) / (scale * scale)
            }
            let decibels = 10 * log10(max(power / Float(bins.count), 1e-12))

            peaks[index] = max(decibels, peaks[index] - Self.peakDecay, Self.silence + Self.range)
            var level = (decibels - (peaks[index] - Self.range)) / Self.range
            level = decibels < Self.silence ? 0 : min(max(level, 0), 1)
            levels[index] = max(level, levels[index] - Self.fall)

            if let drum = Self.drumBands.firstIndex(of: index) {
                // Measured from the silence floor, so a hit out of silence
                // counts by how loud it is rather than as a jump from -∞.
                let floored = max(decibels, Self.silence)
                onsets[drum][onsetCursor] = max(floored - previousDecibels[drum], 0)
                previousDecibels[drum] = floored
            }
        }

        updatePulse(onset: onsets[rhythmDrum][onsetCursor])
        onsetCursor = (onsetCursor + 1) % historyLength

        windowCount += 1
        if windowCount.isMultiple(of: windowsPerRhythmCheck) {
            chooseRhythmBand()
        }
        // About 45 updates a second is plenty for the bars.
        if windowCount.isMultiple(of: 2) {
            onOutput(Output(levels: levels, pulse: pulse, rhythmBand: Self.drumBands[rhythmDrum]))
        }
    }

    private func updatePulse(onset: Float) {
        // Floor of 3dB, so small wobbles in a quiet passage don't pulse.
        onsetPeak = max(onset, onsetPeak * 0.999, 3)
        let strength = max(onset / onsetPeak - Self.pulseThreshold, 0) / (1 - Self.pulseThreshold)
        pulse = max(strength, pulse - Self.pulseFall)
    }

    private func chooseRhythmBand() {
        // Regular and strong: a click that leaks into the other band repeats
        // as regularly as the hit it came with, but much more weakly.
        let rhythms = onsets.indices.map { rhythm(onsets[$0]) }
        let strongest = rhythms.map(\.strength).max() ?? 0
        guard strongest > 0 else { return }
        var scores = rhythms.map { $0.regularity * $0.strength / strongest }
        scores[0] += Self.kickPreference
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }),
              best != rhythmDrum,
              scores[best] > scores[rhythmDrum] + Self.rhythmHysteresis
        else { return }
        rhythmDrum = best
        onsetPeak = 0
    }

    /// `regularity` is the strongest autocorrelation at a beat-length lag,
    /// -1...1, near 1 when hits repeat at a steady tempo. `strength` is how
    /// big the hits are (RMS, in dB).
    private func rhythm(_ ring: [Float]) -> (regularity: Float, strength: Float) {
        vDSP.add(-vDSP.mean(ring), ring, result: &centred)
        let energy = vDSP.sumOfSquares(centred)
        guard energy > 1e-6 else { return (0, 0) }
        // The ring is treated as circular (its seam is one discontinuity in
        // 4s): each lag is the dot product of the two wrapped-around parts.
        let count = centred.count
        var regularity = -Float.infinity
        for lag in beatLags {
            let correlation = vDSP.dot(centred[0..<(count - lag)], centred[lag..<count])
                + vDSP.dot(centred[(count - lag)..<count], centred[0..<lag])
            regularity = max(regularity, correlation / energy)
        }
        return (regularity, (energy / Float(count)).squareRoot())
    }
}

// MARK: - Permission

/// The "System Audio Recording" permission, through the private TCC calls
/// (there's no public API to check or ask for it ahead of capturing).
enum SystemAudioPermission {
    enum Status { case unknown, authorized, denied }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: Request.self)(service, nil, completion)
    }
}
