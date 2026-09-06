//
//  AudioSpectrumTap.swift
//  boringNotch
//
//  Taps the real output of the app that is currently playing with a Core Audio
//  process tap and reduces it to a handful of frequency band levels.
//

import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

let visualizerBandCount = 4

private let fftSize = 1024
private let halfFFTSize = fftSize / 2
private let minimumBandFrequency: Float = 40
private let maximumBandFrequency: Float = 12000
private let noiseFloorDecibels: Float = -70
private let minimumDynamicRange: Float = 25
private let tiltDecibelsPerOctave: Float = 4.5
private let levelReleaseTime: Float = 0.06
private let referenceReleaseTime: Float = 2.0
/// Headroom above the loudest recent band, so peaks stop short of full height
/// instead of pinning the tallest bar to the top every frame.
private let referenceHeadroomDecibels: Float = 6
private let publishInterval: CFAbsoluteTime = 1.0 / 60.0
private let fallbackSampleRate: Double = 48000

/// Windowed real FFT reduced to log-spaced bands. Only touched on the audio queue.
private final class SpectrumAnalyzer {
    private let bandCount: Int
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private var window = [Float](repeating: 0, count: fftSize)
    private var pending: [Float] = []
    private var smoothed: [Float]
    private var bandRanges: [Range<Int>] = []
    private var bandTilts: [Float]
    private var referenceDecibels: Float = noiseFloorDecibels + minimumDynamicRange
    private var sampleRate: Double = fallbackSampleRate
    private var lastAnalysis: CFAbsoluteTime = 0
    private var lastEmission: CFAbsoluteTime = 0

    init(bandCount: Int) {
        self.bandCount = bandCount
        smoothed = [Float](repeating: 0, count: bandCount)
        bandTilts = [Float](repeating: 0, count: bandCount)
        log2n = vDSP_Length(log2(Float(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        pending.reserveCapacity(fftSize * 2)
        updateBands()
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Keeps a sliding window of the most recent samples so successive FFTs
    /// overlap, then returns band levels no faster than the publish interval.
    func consume(_ samples: UnsafeBufferPointer<Float>, sampleRate rate: Double) -> [Float]? {
        if rate > 0, rate != sampleRate {
            sampleRate = rate
            updateBands()
        }

        pending.append(contentsOf: samples)
        if pending.count > fftSize {
            pending.removeFirst(pending.count - fftSize)
        }
        guard pending.count == fftSize else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = lastAnalysis == 0
            ? Float(publishInterval)
            : Float(min(now - lastAnalysis, 0.25))
        lastAnalysis = now

        let levels = analyze(pending, elapsed: elapsed)

        guard now - lastEmission >= publishInterval else { return nil }
        lastEmission = now
        return levels
    }

    private func updateBands() {
        let binWidth = Float(sampleRate) / Float(fftSize)
        let ceiling = min(maximumBandFrequency, Float(sampleRate) / 2)
        let ratio = ceiling / minimumBandFrequency

        var ranges: [Range<Int>] = []
        var tilts: [Float] = []
        for index in 0 ..< bandCount {
            let lower = minimumBandFrequency * pow(ratio, Float(index) / Float(bandCount))
            let upper = minimumBandFrequency * pow(ratio, Float(index + 1) / Float(bandCount))
            let start = max(1, Int(lower / binWidth))
            let end = min(halfFFTSize, max(start + 1, Int(upper / binWidth)))
            ranges.append(start ..< end)

            // Music sheds roughly 4.5 dB per octave as frequency rises, so the
            // upper bands would sit pinned to the floor without this tilt.
            let center = sqrt(lower * upper)
            tilts.append(tiltDecibelsPerOctave * log2(center / minimumBandFrequency))
        }
        bandRanges = ranges
        bandTilts = tilts
    }

    private func analyze(_ frame: [Float], elapsed: Float) -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: halfFFTSize)
        var imaginary = [Float](repeating: 0, count: halfFFTSize)
        var magnitudes = [Float](repeating: 0, count: halfFFTSize)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                            imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfFFTSize) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfFFTSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfFFTSize))
            }
        }

        // vDSP_fft_zrip returns values scaled by 2 * fftSize.
        var scale = 1 / Float(2 * fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfFFTSize))

        var loudest = noiseFloorDecibels
        var bandDecibels = [Float](repeating: 0, count: bandCount)
        for (index, range) in bandRanges.enumerated() {
            var rootMeanSquare: Float = 0
            magnitudes.withUnsafeBufferPointer { pointer in
                vDSP_rmsqv(pointer.baseAddress! + range.lowerBound, 1,
                           &rootMeanSquare, vDSP_Length(range.count))
            }
            let value = 20 * log10(max(rootMeanSquare, .leastNormalMagnitude)) + bandTilts[index]
            bandDecibels[index] = value
            loudest = max(loudest, value)
        }

        // Track the loudest recent band so a quiet track and a heavily mastered
        // one both use the full height of the bars.
        let referenceDecay = exp(-elapsed / referenceReleaseTime)
        referenceDecibels = loudest > referenceDecibels
            ? loudest
            : referenceDecibels * referenceDecay + loudest * (1 - referenceDecay)
        let span = max(referenceDecibels + referenceHeadroomDecibels - noiseFloorDecibels,
                       minimumDynamicRange)

        let levelDecay = exp(-elapsed / levelReleaseTime)
        return bandDecibels.enumerated().map { index, value in
            let level = min(max((value - noiseFloorDecibels) / span, 0), 1)
            let previous = smoothed[index]
            let next = level > previous
                ? level
                : previous * levelDecay + level * (1 - levelDecay)
            smoothed[index] = next
            return next
        }
    }
}

@MainActor
final class AudioSpectrumTap: ObservableObject {
    static let shared = AudioSpectrumTap()

    /// Normalised 0...1 level per frequency band, low to high.
    @Published private(set) var levels = [CGFloat](repeating: 0, count: visualizerBandCount)

    /// True while a process tap is running and feeding real levels.
    @Published private(set) var isLive = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tappedBundleIdentifier: String?
    private let queue = DispatchQueue(label: "com.boringNotch.audioSpectrumTap", qos: .userInitiated)

    private init() {}

    /// Points the tap at the given app, tearing down any previous tap. Passing
    /// nil stops capture entirely.
    func activate(for bundleIdentifier: String?) {
        guard let bundleIdentifier else {
            deactivate()
            return
        }
        guard bundleIdentifier != tappedBundleIdentifier else { return }

        deactivate()

        guard #available(macOS 14.2, *) else { return }
        guard let processObjectID = processObjectID(for: bundleIdentifier) else {
            NSLog("AudioSpectrumTap: no audio process for \(bundleIdentifier)")
            return
        }
        guard startTap(processObjectID: processObjectID) else {
            deactivate()
            return
        }

        tappedBundleIdentifier = bundleIdentifier
        isLive = true
    }

    func deactivate() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        tappedBundleIdentifier = nil
        isLive = false
        levels = [CGFloat](repeating: 0, count: visualizerBandCount)
    }

    // MARK: - Tap plumbing

    @available(macOS 14.2, *)
    private func startTap(processObjectID: AudioObjectID) -> Bool {
        let description = CATapDescription(monoMixdownOfProcesses: [processObjectID])
        description.name = "boringNotch Visualizer"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            NSLog("AudioSpectrumTap: AudioHardwareCreateProcessTap failed")
            return false
        }
        tapID = tap

        guard let outputUID = defaultOutputDeviceUID() else { return false }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "boringNotch Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate) == noErr else {
            NSLog("AudioSpectrumTap: AudioHardwareCreateAggregateDevice failed")
            return false
        }
        aggregateID = aggregate

        let sampleRate = tapSampleRate(tap)
        let analyzer = SpectrumAnalyzer(bandCount: visualizerBandCount)

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let buffer = buffers.first, let data = buffer.mData else { return }

            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            guard let levels = analyzer.consume(samples, sampleRate: sampleRate) else { return }

            let scaled = levels.map { CGFloat($0) }
            Task { @MainActor in
                self?.levels = scaled
            }
        }
        guard status == noErr, let procID else {
            NSLog("AudioSpectrumTap: AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
            return false
        }
        ioProcID = procID

        guard AudioDeviceStart(aggregate, procID) == noErr else {
            NSLog("AudioSpectrumTap: AudioDeviceStart failed")
            return false
        }
        return true
    }

    private func processObjectID(for bundleIdentifier: String) -> AudioObjectID? {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return nil }

        var processIdentifier = application.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &processIdentifier,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr
        else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String?
    }

    private func tapSampleRate(_ tap: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &streamDescription) == noErr,
              streamDescription.mSampleRate > 0
        else { return fallbackSampleRate }
        return streamDescription.mSampleRate
    }
}
