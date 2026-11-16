//
//  Karaoke.swift
//  MusicPlayer
//

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Sing-along mode: plays what the music app is playing with the vocals taken
/// out, like Apple Music Sing.
///
/// Apple Music Sing's own model (which QuietNow loads from MediaPlaybackCore)
/// doesn't ship with macOS, so this uses AUSoundIsolation's built-in high
/// quality voice model the other way round: the unit isolates the voice, and
/// the voice is subtracted from the original. The unit's output lags its input
/// by exactly its reported latency, so the original is delayed by that much to
/// line up.
///
/// The music app's audio is captured with a muted process tap, so the original
/// stops playing, and the result plays to the default output device through
/// the same private aggregate device. It trails the original by the unit's
/// latency (about 0.13s); `delay` lets the lyrics follow it. Like the
/// waveform, it needs the "System Audio Recording" permission.
@MainActor @Observable
final class Karaoke {
    static let shared = Karaoke()

    private(set) var isOn = false

    /// How far the karaoke audio trails the original; 0 while off.
    var delay: TimeInterval { isOn ? latency : 0 }

    private var latency: TimeInterval = 0
    @ObservationIgnored private var engine: KaraokeEngine?
    /// The bundle identifier of the app being processed.
    @ObservationIgnored private var source: String?

    private init() {
        // The aggregate device plays to the output device, so follow switches
        // to headphones and back.
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

// MARK: - Engine

private enum KaraokeError: Error {
    /// The app has no audio process yet, e.g. it hasn't played anything.
    case noAudioProcess
    case noSoundIsolation
}

/// A muted tap of the music app, read and played back through a private
/// aggregate device with `VocalRemover` in between. Audio arrives on `queue`.
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
        // Silences the app while tapped; the processed audio replaces it.
        description.muteBehavior = .muted
        try checkAudio(AudioHardwareCreateProcessTap(description, &tapID))
        aggregateID = try makeTapAggregateDevice(name: "MusicPlayer Karaoke", tap: description.uuid)

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

    /// The Core Audio processes playing for an app: the app and its helpers
    /// (Chrome's audio runs in `com.google.Chrome.helper`), and for Safari,
    /// WebKit's GPU process, which plays its pages' audio.
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

// MARK: - Vocal removal

/// Takes the vocals out of stereo audio: the input, delayed to line up, minus
/// the voice the sound isolation unit isolates from it. Runs on the audio
/// thread, so all its buffers are allocated up front.
///
/// Only part of the isolated voice is subtracted, because the model also
/// picks up things that aren't vocals, and removing those dulled the song
/// (measured on a pop song):
/// - Only its centre (mid): vocals sit in the middle, but the model's output
///   carried nearly as much side content as the song, so subtracting it all
///   cut the stereo width and ambience by 4.4dB.
/// - Only below `voiceCutoff`: above 8kHz the model's output had nearly all of
///   the song's energy (cymbals, hi-hats), so subtracting it cut 8–16kHz by up
///   to 7dB. The low-pass is linear-phase and the original is delayed by its
///   delay too, so the cancellation below the cutoff stays exact.
/// Removal from 300Hz to 8kHz is unchanged by either.
///
/// Of what's left, `vocalRemoval` is subtracted, so a quiet guide vocal stays.
private final class VocalRemover: @unchecked Sendable {
    private static let channels = 2
    /// The most frames rendered at once; longer device buffers are split.
    private static let maxFrames = 4096
    private static let voiceCutoff: Double = 9000
    /// How much of the isolated voice is subtracted. 0.85 (QuietNow's default)
    /// leaves the vocals about 16dB down, as a guide to sing along with.
    private static let vocalRemoval: Float = 0.9
    /// Odd, so the filter's delay is a whole number of frames.
    private static let filterTaps = 95

    /// How far the output trails the input: the unit's latency plus the
    /// low-pass filter's.
    private(set) var latency: TimeInterval = 0
    private let unit: AudioUnit
    /// The slice being processed, per channel: the unit's input.
    private let dry: [UnsafeMutablePointer<Float>]
    /// The unit's output, the isolated voice.
    private let voice: UnsafeMutableAudioBufferListPointer
    private let voiceData: [UnsafeMutablePointer<Float>]
    /// Per channel, the last `delayFrames` of input, to line the original up
    /// with the voice.
    private var delayLines: [UnsafeMutablePointer<Float>] = []
    private var delayFrames = 0
    private var delayCursor = 0
    private var sampleTime: Float64 = 0
    /// The low-pass filter's coefficients, symmetric.
    private var filter: [Float] = []
    /// The last `filterTaps` mid voice samples, written twice
    /// (`filterCursor` and `filterCursor + filterTaps`) so they can always be
    /// read oldest first in one contiguous run.
    private let filterHistory: UnsafeMutablePointer<Float>
    private var filterCursor = 0

    init(sampleRate: Float64) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw KaraokeError.noSoundIsolation }
        var instance: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw KaraokeError.noSoundIsolation }
        unit = instance

        dry = (0..<Self.channels).map { _ in .allocate(capacity: Self.maxFrames) }
        voiceData = (0..<Self.channels).map { _ in .allocate(capacity: Self.maxFrames) }
        voice = AudioBufferList.allocate(maximumBuffers: Self.channels)
        filterHistory = .allocate(capacity: 2 * Self.filterTaps)
        filterHistory.initialize(repeating: 0, count: 2 * Self.filterTaps)

        try configure(sampleRate: sampleRate)
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for buffer in dry + voiceData + delayLines + [filterHistory] {
            buffer.deallocate()
        }
        free(voice.unsafeMutablePointer)
    }

    private func configure(sampleRate: Float64) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            try set(kAudioUnitProperty_StreamFormat, scope, &format)
        }
        var maxFrames = UInt32(Self.maxFrames)
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, &maxFrames)
        var callback = AURenderCallbackStruct(inputProc: Self.supplyInput, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, &callback)

        // The high quality model isolates sung vocals far better than the
        // default one (about 4× the voice energy, measured on a pop song).
        try checkAudio(AudioUnitSetParameter(
            unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0
        ))
        // Fully wet: the output is the voice alone.
        try checkAudio(AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0))
        try checkAudio(AudioUnitInitialize(unit))

        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try checkAudio(AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size))
        filter = Self.lowPass(cutoff: Self.voiceCutoff / sampleRate, taps: Self.filterTaps)
        delayFrames = Int((latency * sampleRate).rounded()) + (Self.filterTaps - 1) / 2
        self.latency = Double(delayFrames) / sampleRate
        delayLines = (0..<Self.channels).map { _ in
            let line = UnsafeMutablePointer<Float>.allocate(capacity: max(delayFrames, 1))
            line.initialize(repeating: 0, count: max(delayFrames, 1))
            return line
        }
    }

    /// A windowed-sinc (Blackman) low-pass, linear-phase, normalised to unity
    /// gain. `cutoff` is a fraction of the sample rate.
    private static func lowPass(cutoff: Double, taps: Int) -> [Float] {
        let middle = Double(taps - 1) / 2
        let coefficients = (0..<taps).map { index -> Double in
            let x = Double(index) - middle
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let phase = 2 * .pi * Double(index) / Double(taps - 1)
            return sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
        }
        let sum = coefficients.reduce(0, +)
        return coefficients.map { Float($0 / sum) }
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ value: inout T) throws {
        try checkAudio(AudioUnitSetProperty(unit, property, scope, 0, &value, UInt32(MemoryLayout<T>.size)))
    }

    /// Hands the unit the slice in `dry`.
    private static let supplyInput: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        guard let ioData else { return kAudio_ParamError }
        let remover = Unmanaged<VocalRemover>.fromOpaque(refCon).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let bytes = Int(frameCount) * MemoryLayout<Float>.size
        for channel in 0..<min(buffers.count, channels) {
            if let data = buffers[channel].mData {
                data.copyMemory(from: remover.dry[channel], byteCount: bytes)
            } else {
                buffers[channel].mData = UnsafeMutableRawPointer(remover.dry[channel])
            }
            buffers[channel].mDataByteSize = UInt32(bytes)
        }
        return noErr
    }

    /// `input` is the aggregate device's input: the tap's interleaved stereo
    /// stream comes after any input streams of the output device, so it's the
    /// last buffer. The result goes to the output device's first stream.
    func process(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let tap = inputs.last, let tapData = tap.mData, tap.mNumberChannels > 0,
              let out = outputs.first, let outData = out.mData, out.mNumberChannels > 0
        else { return }

        let tapChannels = Int(tap.mNumberChannels)
        let outChannels = Int(out.mNumberChannels)
        let samples = tapData.assumingMemoryBound(to: Float.self)
        let result = outData.assumingMemoryBound(to: Float.self)
        let total = min(
            Int(tap.mDataByteSize) / (tapChannels * MemoryLayout<Float>.size),
            Int(out.mDataByteSize) / (outChannels * MemoryLayout<Float>.size)
        )

        var offset = 0
        while offset < total {
            let count = min(total - offset, Self.maxFrames)
            for frame in 0..<count {
                let base = (offset + frame) * tapChannels
                dry[0][frame] = samples[base]
                dry[1][frame] = samples[base + min(1, tapChannels - 1)]
            }
            renderVoice(count)
            for frame in 0..<count {
                let base = (offset + frame) * outChannels
                let vocals = filteredMid(frame)
                for channel in 0..<Self.channels {
                    var original = dry[channel][frame]
                    if delayFrames > 0 {
                        let line = delayLines[channel]
                        (original, line[delayCursor]) = (line[delayCursor], original)
                    }
                    if channel < outChannels {
                        result[base + channel] = original - Self.vocalRemoval * vocals
                    }
                }
                if delayFrames > 0 {
                    delayCursor = (delayCursor + 1) % delayFrames
                }
            }
            offset += count
        }
    }

    /// The centre of the voice at `frame`, low-passed.
    private func filteredMid(_ frame: Int) -> Float {
        let mid = (voiceData[0][frame] + voiceData[1][frame]) / 2
        filterHistory[filterCursor] = mid
        filterHistory[filterCursor + Self.filterTaps] = mid
        filterCursor = (filterCursor + 1) % Self.filterTaps
        // The coefficients are symmetric, so no need to reverse them.
        var sum: Float = 0
        vDSP_dotpr(filterHistory + filterCursor, 1, filter, 1, &sum, vDSP_Length(Self.filterTaps))
        return sum
    }

    /// Fills `voiceData` from `dry`; silence if the unit fails, which leaves
    /// the original playing.
    private func renderVoice(_ count: Int) {
        for channel in 0..<Self.channels {
            voice[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(voiceData[channel])
            )
        }
        var flags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid
        let status = AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(count), voice.unsafeMutablePointer)
        sampleTime += Float64(count)
        if status != noErr {
            for channel in 0..<Self.channels {
                voiceData[channel].update(repeating: 0, count: count)
            }
        }
    }
}
