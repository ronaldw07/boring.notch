//
//  AppVolumeTap.swift
//  boringNotch
//
//  Scales one app's audio. macOS has no per-app volume setting, so this
//  does what mixers like Ear Trumpet do: a Core Audio process tap captures
//  the app's output and mutes the original, and an IO proc plays the same
//  samples back through the real output device multiplied by a gain.
//

import AudioToolbox
import CoreAudio
import Foundation

/// Gain shared between the main thread (writes the target) and the audio
/// thread (ramps toward it). A single aligned Float, so plain reads and
/// writes are enough; locking in an audio callback would be worse.
final class GainBox: @unchecked Sendable {
    nonisolated(unsafe) var target: Float
    nonisolated(unsafe) var applied: Float

    init(_ value: Float) {
        target = value
        applied = value
    }
}

@available(macOS 14.2, *)
final class AppVolumeTap {
    let processObjectIDs: Set<AudioObjectID>

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.boringNotch.appVolumeTap", qos: .userInteractive)

    /// Nil if the tap couldn't be built — most often because audio capture
    /// hasn't been allowed in System Settings › Privacy & Security.
    init?(processObjectIDs: Set<AudioObjectID>, name: String, gain: GainBox) {
        self.processObjectIDs = processObjectIDs
        guard start(name: name, gain: gain) else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
    }

    func stop() {
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
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func start(name: String, gain: GainBox) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        description.name = "boringNotch \(name)"
        description.uuid = UUID()
        description.isPrivate = true
        // The original path goes silent, so the only thing heard is what the
        // IO proc below plays back, scaled.
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            NSLog("AppVolumeTap: create tap failed (\(tapStatus))")
            return false
        }
        tapID = tap

        guard let outputUID = Self.defaultOutputDeviceUID() else { return false }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "boringNotch \(name)",
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
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr else {
            NSLog("AppVolumeTap: create aggregate failed (\(aggregateStatus))")
            return false
        }
        aggregateID = aggregate

        let tapChannels = Self.tapChannelCount(tap)
        let sampleRate = Self.deviceSampleRate(aggregate)

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, inputData, _, outputData, _ in
            Self.render(input: inputData, output: outputData, tapChannels: tapChannels,
                        gain: gain, sampleRate: sampleRate)
        }
        guard procStatus == noErr, let procID else {
            NSLog("AppVolumeTap: create IO proc failed (\(procStatus))")
            return false
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            NSLog("AppVolumeTap: start failed (\(startStatus))")
            return false
        }
        return true
    }

    // MARK: - Render

    /// How long a gain change takes to arrive, so dragging a slider doesn't
    /// click.
    private static let rampSeconds: Float = 0.03

    /// Copies the tapped samples to the output, scaled, ramping the gain
    /// across the buffer. Runs on the audio thread: no allocation, no locks.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        tapChannels: Int,
        gain: GainBox,
        sampleRate: Double
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // The tap's stream is appended after any stream the output device
        // itself has as input (a headset's mic, say), so look from the end
        // for the buffer with the tap's channel count.
        var tapBuffer: AudioBuffer?
        for index in stride(from: inputs.count - 1, through: 0, by: -1)
            where Int(inputs[index].mNumberChannels) == tapChannels {
            tapBuffer = inputs[index]
            break
        }

        let start = gain.applied
        let end = gain.target

        for outIndex in 0 ..< outputs.count {
            let outBuffer = outputs[outIndex]
            guard let outData = outBuffer.mData else { continue }
            let outChannels = max(1, Int(outBuffer.mNumberChannels))
            let outFrames = Int(outBuffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let out = outData.assumingMemoryBound(to: Float.self)

            guard outIndex == 0, let tapBuffer, let inData = tapBuffer.mData else {
                memset(outData, 0, Int(outBuffer.mDataByteSize))
                continue
            }
            let inChannels = max(1, Int(tapBuffer.mNumberChannels))
            let inFrames = Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let inp = inData.assumingMemoryBound(to: Float.self)
            let frames = min(inFrames, outFrames)

            let rampFrames = max(1, min(frames, Int(rampSeconds * Float(sampleRate))))
            let step = (end - start) / Float(rampFrames)

            for frame in 0 ..< frames {
                // From the frame index, not by adding up steps, which
                // drifts enough to overshoot the target.
                let g = frame + 1 < rampFrames ? start + step * Float(frame + 1) : end
                for channel in 0 ..< outChannels {
                    out[frame * outChannels + channel] = channel < inChannels
                        ? inp[frame * inChannels + channel] * g
                        : 0
                }
            }
            if frames < outFrames {
                memset(out + frames * outChannels, 0, (outFrames - frames) * outChannels * MemoryLayout<Float>.size)
            }
        }
        gain.applied = end
    }

    // MARK: - Device queries

    static func defaultOutputDeviceUID() -> String? {
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

    private static func tapChannelCount(_ tap: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mChannelsPerFrame > 0
        else { return 2 }
        return Int(format.mChannelsPerFrame)
    }

    private static func deviceSampleRate(_ device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0
        else { return 48000 }
        return rate
    }
}
