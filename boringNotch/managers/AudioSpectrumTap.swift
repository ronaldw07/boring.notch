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
private let maximumBandFrequency: Float = 8000
private let noiseFloorDecibels: Float = -55
private let peakDecibels: Float = -10
private let releaseCoefficient: Float = 0.80
private let publishInterval: CFAbsoluteTime = 1.0 / 30.0
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
    private var sampleRate: Double = fallbackSampleRate
    private var lastEmission: CFAbsoluteTime = 0

    init(bandCount: Int) {
        self.bandCount = bandCount
        smoothed = [Float](repeating: 0, count: bandCount)
        log2n = vDSP_Length(log2(Float(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        pending.reserveCapacity(fftSize * 2)
        updateBandRanges()
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Returns band levels once a full frame has accumulated and the publish
    /// interval has elapsed, otherwise nil.
    func consume(_ samples: UnsafeBufferPointer<Float>, sampleRate rate: Double) -> [Float]? {
        if rate > 0, rate != sampleRate {
            sampleRate = rate
            updateBandRanges()
        }

        pending.append(contentsOf: samples)
        guard pending.count >= fftSize else { return nil }

        let frame = Array(pending.suffix(fftSize))
        pending.removeAll(keepingCapacity: true)

        let levels = analyze(frame)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmission >= publishInterval else { return nil }
        lastEmission = now
        return levels
    }

    private func updateBandRanges() {
        let binWidth = Float(sampleRate) / Float(fftSize)
        let ratio = maximumBandFrequency / minimumBandFrequency
        bandRanges = (0 ..< bandCount).map { index in
            let lower = minimumBandFrequency * pow(ratio, Float(index) / Float(bandCount))
            let upper = minimumBandFrequency * pow(ratio, Float(index + 1) / Float(bandCount))
            let start = max(1, Int(lower / binWidth))
            let end = min(halfFFTSize, max(start + 1, Int(upper / binWidth)))
            return start ..< end
        }
    }

    private func analyze(_ frame: [Float]) -> [Float] {
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

        return bandRanges.enumerated().map { index, range in
            var mean: Float = 0
            magnitudes.withUnsafeBufferPointer { pointer in
                vDSP_meanv(pointer.baseAddress! + range.lowerBound, 1, &mean, vDSP_Length(range.count))
            }
            let decibels = 20 * log10(max(mean, .leastNormalMagnitude))
            let normalized = (decibels - noiseFloorDecibels) / (peakDecibels - noiseFloorDecibels)
            let level = min(max(normalized, 0), 1)

            let previous = smoothed[index]
            let next = level > previous
                ? level
                : previous * releaseCoefficient + level * (1 - releaseCoefficient)
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
