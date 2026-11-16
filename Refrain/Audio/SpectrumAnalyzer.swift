import Accelerate
import CoreAudio
import Foundation

/// FFTs overlapping 1024-sample windows into band levels, each normalised to its own
/// decaying recent peak. The pulse follows whichever drum band (kick or snare body)
/// has the most regular onsets; treble is excluded because hi-hats are just as regular.
final class SpectrumAnalyzer: @unchecked Sendable {
    struct Output {
        var levels: [Float]
        var pulse: Float
        var rhythmBand: Int
    }

    private static let size = 1024
    private static let hop = 512
    private static let edges: [Double] = [40, 150, 400, 1000, 3000, 10000]
    private static let silence: Float = -70
    private static let range: Float = 24
    private static let peakDecay: Float = 0.05
    private static let fall: Float = 0.05
    private static let pulseFall: Float = 0.035
    private static let pulseThreshold: Float = 0.3
    private static let rhythmHysteresis: Float = 0.1
    private static let drumBands = [0, 1]
    private static let kickPreference: Float = 0.15

    private let channels: Int
    private let bands: [Range<Int>]
    // Preallocated: this runs about 94 times a second.
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

    private var previousDecibels = [Float](repeating: silence, count: drumBands.count)
    private var onsets: [[Float]]
    private var onsetCursor = 0
    private var onsetPeak: Float = 0
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

    /// Interleaved samples; only the first channel is used.
    func process(_ samples: UnsafeBufferPointer<Float>) {
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
                // From the silence floor, so a hit out of silence isn't a jump from -∞.
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
        if windowCount.isMultiple(of: 2) {
            onOutput(Output(levels: levels, pulse: pulse, rhythmBand: Self.drumBands[rhythmDrum]))
        }
    }

    private func updatePulse(onset: Float) {
        onsetPeak = max(onset, onsetPeak * 0.999, 3)
        let strength = max(onset / onsetPeak - Self.pulseThreshold, 0) / (1 - Self.pulseThreshold)
        pulse = max(strength, pulse - Self.pulseFall)
    }

    private func chooseRhythmBand() {
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

    /// Peak autocorrelation over beat-length lags (treating the ring as circular), and RMS strength.
    private func rhythm(_ ring: [Float]) -> (regularity: Float, strength: Float) {
        vDSP.add(-vDSP.mean(ring), ring, result: &centred)
        let energy = vDSP.sumOfSquares(centred)
        guard energy > 1e-6 else { return (0, 0) }
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
