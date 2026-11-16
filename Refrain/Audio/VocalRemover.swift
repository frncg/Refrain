import Accelerate
import AudioToolbox
import Foundation

/// Subtracts AUSoundIsolation's isolated voice from the delayed original. Only the
/// voice's mid, low-passed at 9kHz, is subtracted: its sides and highs are mostly
/// ambience and cymbals. Runs on the audio thread, so buffers are preallocated.
final class VocalRemover: @unchecked Sendable {
    private static let channels = 2
    private static let maxFrames = 4096
    private static let voiceCutoff: Double = 9000
    private static let vocalRemoval: Float = 0.9
    /// Odd, so the filter's delay is a whole number of frames.
    private static let filterTaps = 95

    private(set) var latency: TimeInterval = 0
    private let unit: AudioUnit
    private let dry: [UnsafeMutablePointer<Float>]
    private let voice: UnsafeMutableAudioBufferListPointer
    private let voiceData: [UnsafeMutablePointer<Float>]
    private var delayLines: [UnsafeMutablePointer<Float>] = []
    private var delayFrames = 0
    private var delayCursor = 0
    private var sampleTime: Float64 = 0
    private var filter: [Float] = []
    /// Written twice (`filterCursor` and `+ filterTaps`) so it reads oldest first in one run.
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

    /// Blackman-windowed sinc, linear-phase, unity gain. `cutoff` is a fraction of the sample rate.
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

    /// The tap is the input's last buffer (after the output device's own inputs);
    /// the result goes to the output device's first stream.
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

    private func filteredMid(_ frame: Int) -> Float {
        let mid = (voiceData[0][frame] + voiceData[1][frame]) / 2
        filterHistory[filterCursor] = mid
        filterHistory[filterCursor + Self.filterTaps] = mid
        filterCursor = (filterCursor + 1) % Self.filterTaps
        var sum: Float = 0
        vDSP_dotpr(filterHistory + filterCursor, 1, filter, 1, &sum, vDSP_Length(Self.filterTaps))
        return sum
    }

    /// On failure the voice is silence, which leaves the original playing.
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
