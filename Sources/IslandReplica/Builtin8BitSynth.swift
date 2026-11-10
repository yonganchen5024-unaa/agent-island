import AVFoundation
import Foundation

/// Candidate reconstructed from Vibe Island 1.0.55 arm64 function 0x100c3f8dc.
/// Event assignment follows the observed enum jump table and remains unverified.
struct Builtin8BitSynth {
    static let sampleRate: Float = 48_000
    enum Wave { case square, triangle }
    struct Voice { let start: Float; let duration: Float; let frequency: Float; let amplitude: Float; let attack: Float; let release: Float; let wave: Wave; var risingRatio: Float? = nil; var glideDivisor: Float = 1; var inversePeriod: Bool = false }
    static let taskCompleteVoices: [Voice] = [
        Voice(start:0, duration:0.07, frequency:659.25, amplitude:0.20, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.08, duration:0.07, frequency:783.99, amplitude:0.20, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.16, duration:0.55, frequency:1046.5, amplitude:0.22, attack:0.005, release:0.25, wave:.square),
        Voice(start:0.16, duration:0.55, frequency:523.25, amplitude:0.10, attack:0.005, release:0.20, wave:.triangle),
        Voice(start:0.50, duration:0.50, frequency:1046.5, amplitude:0.04, attack:0.005, release:0.20, wave:.triangle)
    ]
    static let sessionStartVoices: [Voice] = [
        Voice(start:0, duration:0.10, frequency:523.25, amplitude:0.22, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.10, duration:0.10, frequency:659.25, amplitude:0.22, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.20, duration:0.22, frequency:783.99, amplitude:0.25, attack:0.005, release:0.02, wave:.square),
        Voice(start:0, duration:0.40, frequency:261.63, amplitude:0.06, attack:0.005, release:0.10, wave:.triangle)
    ]
    static let taskErrorVoices: [Voice] = {
        var voices: [Voice] = []
        for (index, frequency) in [Float(261.63), Float(220), Float(174.61)].enumerated() {
            let start = Float(index) * Float(0.13)
            voices.append(Voice(start:start, duration:0.12, frequency:frequency, amplitude:0.20, attack:0.005, release:0.015, wave:.square))
            voices.append(Voice(start:start, duration:0.12, frequency:frequency * Float(1.015), amplitude:0.12, attack:0.005, release:0.015, wave:.square))
        }
        voices.append(Voice(start:0, duration:0.40, frequency:87.305, amplitude:0.06, attack:0.005, release:0.10, wave:.triangle))
        return voices
    }()
    static let inputRequiredVoices: [Voice] = [
        Voice(start:0, duration:0.10, frequency:523.25, amplitude:0.20, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.10, duration:0.10, frequency:698.46, amplitude:0.22, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.28, duration:0.10, frequency:698.46, amplitude:0.20, attack:0.005, release:0.02, wave:.square),
        Voice(start:0.38, duration:0.16, frequency:880, amplitude:0.21, attack:0.005, release:0.03, wave:.square),
        Voice(start:0, duration:0.50, frequency:174.61, amplitude:0.05, attack:0.005, release:0.10, wave:.triangle)
    ]
    static let questionVoices: [Voice] = [
        Voice(start:0, duration:0.30, frequency:523.25, amplitude:0.20, attack:0.008, release:0.06, wave:.triangle, risingRatio: Float(bitPattern:0x3fa144dd), glideDivisor: Float(bitPattern:0x3f547ae1), inversePeriod:true),
        Voice(start:0.10, duration:0.20, frequency:783.99, amplitude:0.06, attack:0.005, release:0.04, wave:.triangle)
    ]
    static let acknowledgeVoices: [Voice] = [
        Voice(start:0, duration:0.055, frequency:987.76, amplitude:0.20, attack:0.004, release:0.008, wave:.square),
        Voice(start:0.06, duration:0.12, frequency:1318.51, amplitude:0.24, attack:0.008, release:0.018, wave:.square)
    ]
    static let resourceLimitVoices: [Voice] = zip([Float(0), 0.15, 0.27, 0.36], [Float(0.15), 0.18, 0.22, 0.25]).map {
        Voice(start:$0.0, duration:0.06, frequency:440, amplitude:$0.1, attack:0.003, release:0.01, wave:.square)
    }
    static let userSpamVoices: [Voice] = [
        Voice(start:0, duration:0.15, frequency:1046.5, amplitude:0.20, attack:0.008, release:0.0375, wave:.square, risingRatio: Float(bitPattern:0x3e8000a0), inversePeriod:true),
        Voice(start:0.18, duration:0.08, frequency:329.63, amplitude:0.15, attack:0.003, release:0.015, wave:.square),
        Voice(start:0.26, duration:0.08, frequency:196, amplitude:0.10, attack:0.003, release:0.015, wave:.square)
    ]
    static let usageWarningVoices: [Voice] = {
        var voices: [Voice] = []
        let groups: [(Float, Float, Float, Float, Float, Float)] = [
            (0, 0.09, 392, 0.18, 0.10, 0.015),
            (0.09, 0.09, 329.63, 0.18, 0.10, 0.015),
            (0.28, 0.11, 392, 0.20, 0.11, 0.015),
            (0.39, 0.13, 329.63, 0.20, 0.11, 0.04)
        ]
        for (start, length, frequency, amplitude, detunedAmplitude, release) in groups {
            voices.append(Voice(start:start, duration:length, frequency:frequency, amplitude:amplitude, attack:0.005, release:release, wave:.square))
            voices.append(Voice(start:start, duration:length, frequency:frequency * Float(1.012), amplitude:detunedAmplitude, attack:0.005, release:release, wave:.square))
        }
        voices.append(Voice(start:0, duration:0.6, frequency:196, amplitude:0.05, attack:0.005, release:0.1, wave:.triangle))
        return voices
    }()
    static let idleReminderVoices: [Voice] = [
        Voice(start:0, duration:0.10, frequency:880, amplitude:0.10, attack:0.01, release:0.06, wave:.triangle),
        Voice(start:0.09, duration:0.10, frequency:1046.5, amplitude:0.10, attack:0.01, release:0.06, wave:.triangle),
        Voice(start:0, duration:0.28, frequency:220, amplitude:0.025, attack:0.01, release:0.08, wave:.triangle)
    ]
    static let usageResetVoices: [Voice] = [
        Voice(start:0, duration:0.07, frequency:523.25, amplitude:0.18, attack:0.005, release:0.018, wave:.square),
        Voice(start:0.08, duration:0.07, frequency:659.25, amplitude:0.19, attack:0.005, release:0.018, wave:.square),
        Voice(start:0.16, duration:0.07, frequency:783.99, amplitude:0.20, attack:0.005, release:0.018, wave:.square),
        Voice(start:0.24, duration:0.24, frequency:1046.5, amplitude:0.22, attack:0.005, release:0.1, wave:.square),
        Voice(start:0.24, duration:0.28, frequency:523.25, amplitude:0.08, attack:0.005, release:0.12, wave:.triangle),
        Voice(start:0.35, duration:0.2, frequency:1318.51, amplitude:0.04, attack:0.01, release:0.08, wave:.triangle),
        Voice(start:0, duration:0.5, frequency:261.63, amplitude:0.06, attack:0.005, release:0.12, wave:.triangle),
        Voice(start:0, duration:0.4, frequency:130.815, amplitude:0.04, attack:0.005, release:0.1, wave:.triangle)
    ]
    static func taskComplete() -> [Float] { render(duration:1.1, voices:taskCompleteVoices) }
    static func sessionStart() -> [Float] { render(duration:0.5, voices:sessionStartVoices) }
    static func taskError() -> [Float] { render(duration:0.5, voices:taskErrorVoices) }
    static func inputRequired() -> [Float] { render(duration:0.6, voices:inputRequiredVoices) }
    static func question() -> [Float] { render(duration:0.4, voices:questionVoices) }
    static func taskAcknowledge() -> [Float] { render(duration:0.22, voices:acknowledgeVoices) }
    static func resourceLimit() -> [Float] { render(duration:0.5, voices:resourceLimitVoices) }
    static func userSpam() -> [Float] { render(duration:0.35, voices:userSpamVoices) }
    static func usageWarning() -> [Float] { render(duration:0.7, voices:usageWarningVoices) }
    static func idleReminder() -> [Float] { render(duration:0.35, voices:idleReminderVoices) }
    static func usageReset() -> [Float] { render(duration:0.65, voices:usageResetVoices) }
    /// Candidate reconstruction of the longer harmonic reset-card tone.
    static func resetCard() -> [Float] {
        let rate = sampleRate
        let total = Int(Float(1.8) * rate)
        var result = [Float](repeating: 0, count: total)
        func envelope(_ i: Int, _ length: Int, _ attack: Int, _ release: Int) -> Float {
            var a: Float = 1
            if attack > 0 && i < attack { a = 0.5 - 0.5 * cosf(Float.pi * Float(i) / Float(attack)) }
            let remaining = length - i
            if release > 0 && remaining < release { a *= 0.5 - 0.5 * cosf(Float.pi * Float(remaining) / Float(release)) }
            return a
        }
        let tones: [(Float, Float, Float, Float)] = [(783.99,0,0.161,0.4), (1046.5,0.06,0.179,0.5), (1318.51,0.12,0.215,0.9)]
        for (frequency, start, amplitude, decay) in tones {
            let offset = Int(start * rate)
            let length = min(total - offset, Int((Float(1.8) - start) * rate))
            let attack = Int(Float(0.003) * rate), release = Int(Float(0.3) * rate)
            let step = Double(frequency) * 2 * Double.pi / Double(rate)
            for i in 0..<length {
                let t = Float(i) / rate, phase = step * Double(i)
                let a = Float(sin(phase)) * expf(-t / decay)
                let b = Float(0.28) * Float(sin(2 * phase + Double(Float(1.7)))) * expf(-t / (decay * Float(0.45)))
                let c = Float(0.10) * Float(sin(3 * phase + Double(Float(3.4)))) * expf(-t / (decay * Float(0.3)))
                let d = Float(0.03) * Float(sin(4 * phase + Double(Float(5.1)))) * expf(-t / Float(0.012))
                result[offset + i] += (a + b + c + d) * amplitude * envelope(i, length, attack, release)
            }
        }
        let offset = Int(Float(0.12) * rate)
        let length = min(total - offset, Int(Float(1.68) * rate))
        let release = Int(Float(0.3) * rate)
        let attackA = Int(Float(0.015) * rate), attackB = Int(Float(0.006) * rate), attackC = Int(Float(0.008) * rate)
        for i in 0..<length {
            let t = Float(i) / rate, index = Double(i), sampleRate = Double(rate)
            let phaseA = (9851.908775232985 / sampleRate) * index
            let phaseB = (2 * Double.pi * Double(Float(523.25)) / sampleRate) * index
            let phaseC = (1643.869802597011 / sampleRate) * index
            let a = Float(0.063) * Float(sin(phaseA)) * expf(-t / Float(0.9)) * envelope(i, length, attackA, release)
            let b1 = Float(sin(phaseB)) * expf(-t / Float(0.7))
            let b2 = Float(0.15) * Float(sin(2 * phaseB + Double(Float(1.7)))) * expf(-t / Float(0.2))
            let b = Float(0.163) * (b1 + b2) * envelope(i, length, attackB, release)
            let c = Float(0.116) * Float(sin(phaseC)) * expf(-t / Float(0.63)) * envelope(i, length, attackC, release)
            result[offset + i] += a; result[offset + i] += b; result[offset + i] += c
        }
        for i in result.indices { result[i] = min(max(result[i] * 1.5, -1), 1) }
        return result
    }
    private static func render(duration: Float, voices: [Voice]) -> [Float] {
        let frames = Int(duration * sampleRate)
        var result = [Float](repeating: 0, count: frames)
        for voice in voices {
            let start = Int(voice.start * sampleRate)
            let length = Int(voice.duration * sampleRate)
            let attack = Int(voice.attack * sampleRate)
            let release = Int(voice.release * sampleRate)
            let period = sampleRate / voice.frequency
            var accumulatedPhase: Float = 0
            for i in 0..<length where start + i < frames {
                let phase: Float
                if let ratio = voice.risingRatio {
                    let progress = min((Float(i) / Float(length)) / voice.glideDivisor, 1)
                    let instantFrequency = voice.frequency * powf(ratio, progress)
                    accumulatedPhase += voice.inversePeriod ? 1 / (sampleRate / instantFrequency) : instantFrequency / sampleRate
                    if accumulatedPhase >= 1 { accumulatedPhase -= 1 }
                    phase = accumulatedPhase
                } else {
                    phase = Float(i).truncatingRemainder(dividingBy: period) / period
                }
                let value: Float
                switch voice.wave {
                case .square: value = phase < 0.5 ? voice.amplitude : -voice.amplitude
                case .triangle: value = (2 * abs(2 * phase - 1) - 1) * voice.amplitude
                }
                let envelope: Float
                if attack > 0 && i < attack { envelope = Float(i) / Float(attack) }
                else if release > 0 && i >= length - release { envelope = Float(length - i) / Float(release) }
                else { envelope = 1 }
                result[start + i] += value * envelope
            }
        }
        for i in result.indices { result[i] = min(max(result[i] * 1.5, -1), 1) }
        return result
    }
}

@MainActor final class Builtin8BitPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    func play(_ samples: [Float], volume: Float) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(Builtin8BitSynth.sampleRate), channels: 1) else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in if let base = source.baseAddress { channel.update(from: base, count: samples.count) } }
        do {
            if !attached { engine.attach(player); engine.connect(player, to:engine.mainMixerNode, format:format); attached = true }
            if !engine.isRunning { try engine.start() }
            player.stop(); player.volume = volume; player.scheduleBuffer(buffer, completionHandler:nil); player.play()
            return true
        } catch { return false }
    }
}
