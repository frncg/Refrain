//
//  SpectrumAnalyzerTests.swift
//  MusicPlayerTests
//

import Foundation
import Testing
@testable import MusicPlayer

struct SpectrumAnalyzerTests {

    /// Bands are bass first: 40–150, 150–400, 400–1k, 1k–3k and 3k–10k Hz.
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

    /// Kick-like (100 Hz) or snare-like (250 Hz) hits twice a second over a
    /// steady treble tone: the drum that's hit regularly drives the pulse.
    @Test(arguments: [(100.0, 0), (250.0, 1)])
    func pulseFollowsTheDrums(hit: Double, band: Int) {
        let outputs = outputs(hits(at: hit, over: 5000))
        #expect(outputs.last?.rhythmBand == band)

        // The pulse spikes on hits and fades between them.
        let pulses = outputs.suffix(200).map(\.pulse)
        #expect(pulses.max()! > 0.9)
        #expect(pulses.min()! < 0.1)
    }

    /// Hi-hat-like treble hits over a steady bass don't pulse, however regular.
    @Test func trebleHitsDontPulse() {
        let outputs = outputs(hits(at: 5000, over: 100))
        #expect(outputs.suffix(200).map(\.pulse).max()! < 0.1)
    }

    /// Drum-like hits of `hit` Hz twice a second, for 8s, over a steady tone.
    /// Each hit has a 5ms attack and decays over ~50ms; switching a tone on
    /// instantly instead would click across every band, which drums don't.
    private func hits(at hit: Double, over steady: Double) -> [Float] {
        (0..<(8 * 48_000)).map { index -> Float in
            let time = Double(index) / 48_000
            let sinceHit = time.truncatingRemainder(dividingBy: 0.5)
            let envelope = sinceHit < 0.005 ? sinceHit / 0.005 : exp(-(sinceHit - 0.005) / 0.05)
            return Float(0.3 * sin(2 * .pi * steady * time) + 0.5 * envelope * sin(2 * .pi * hit * time))
        }
    }

    /// The last levels reported for `samples`.
    private func analyze(_ samples: [Float]) -> [Float] {
        outputs(samples).last?.levels ?? []
    }

    /// Everything reported for `samples`, fed in tap-sized buffers.
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
