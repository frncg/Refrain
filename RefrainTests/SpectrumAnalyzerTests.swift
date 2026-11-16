import Foundation
import Testing
@testable import Refrain

struct SpectrumAnalyzerTests {

    @Test(arguments: [(100.0, 0), (250.0, 1), (700.0, 2), (2000.0, 3), (5000.0, 4)])
    func toneLightsItsBand(frequency: Double, band: Int) {
        let levels = analyze(tone(frequency, amplitude: 0.5))
        #expect(levels.firstIndex(of: levels.max()!) == band, "\(levels)")
        #expect(levels[band] > 0.9, "\(levels)")
    }

    @Test func silenceIsFlat() {
        #expect(analyze([Float](repeating: 0, count: 48_000)) == [0, 0, 0, 0, 0])
    }

    private func tone(_ frequency: Double, amplitude: Float) -> [Float] {
        (0..<48_000).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 48_000)) }
    }

    @Test(arguments: [(100.0, 0), (250.0, 1)])
    func pulseFollowsTheDrums(hit: Double, band: Int) {
        let outputs = outputs(hits(at: hit, over: 5000))
        #expect(outputs.last?.rhythmBand == band)

        let pulses = outputs.suffix(200).map(\.pulse)
        #expect(pulses.max()! > 0.9)
        #expect(pulses.min()! < 0.1)
    }

    @Test func trebleHitsDontPulse() {
        let outputs = outputs(hits(at: 5000, over: 100))
        #expect(outputs.suffix(200).map(\.pulse).max()! < 0.1)
    }

    /// Hits need a soft attack: a tone switched on instantly clicks across every band.
    private func hits(at hit: Double, over steady: Double) -> [Float] {
        (0..<(8 * 48_000)).map { index -> Float in
            let time = Double(index) / 48_000
            let sinceHit = time.truncatingRemainder(dividingBy: 0.5)
            let envelope = sinceHit < 0.005 ? sinceHit / 0.005 : exp(-(sinceHit - 0.005) / 0.05)
            return Float(0.3 * sin(2 * .pi * steady * time) + 0.5 * envelope * sin(2 * .pi * hit * time))
        }
    }

    private func analyze(_ samples: [Float]) -> [Float] {
        outputs(samples).last?.levels ?? []
    }

    private func outputs(_ samples: [Float]) -> [SpectrumAnalyzer.Output] {
        let collected = Collected()
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000, channels: 1) { collected.outputs.append($0) }
        samples.withUnsafeBufferPointer { buffer in
            for start in stride(from: 0, to: buffer.count, by: 512) {
                analyzer.process(UnsafeBufferPointer(rebasing: buffer[start..<min(start + 512, buffer.count)]))
            }
        }
        return collected.outputs
    }

    private final class Collected: @unchecked Sendable {
        var outputs: [SpectrumAnalyzer.Output] = []
    }
}
