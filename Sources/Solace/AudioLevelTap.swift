import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

/// Listens to what the Mac is playing (system output) using a Core Audio process tap
/// (macOS 14.2+), the same mechanism system-audio visualisers use. It only measures
/// loudness — nothing is recorded or stored. Requires the one-time
/// "System Audio Recording" permission; if denied (or if a source is protected)
/// the buffers are silent and the app falls back to a gentle pulse.
final class AudioLevelTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "halo.audiotap", qos: .userInteractive)

    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    private var lowpass: Float = 0

    private(set) var isRunning = false

    /// Latest loudness (bass-weighted RMS), roughly 0...1. Safe to call from any thread.
    func level() -> Float { lock.withLock { $0 } }

    func start() throws {
        guard !isRunning else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Solace Ambient"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        guard err == noErr else { throw TapError.os("create tap", err) }
        tapID = newTap

        let outputUID = try Self.defaultOutputUID()
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Solace Ambient Tap",
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

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAgg)
        guard err == noErr else { stop(); throw TapError.os("create aggregate", err) }
        aggregateID = newAgg

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.process(inInputData)
        }
        guard err == noErr else { stop(); throw TapError.os("create io proc", err) }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { stop(); throw TapError.os("start device", err) }

        isRunning = true
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
        isRunning = false
        lock.withLock { $0 = 0 }
    }

    deinit { stop() }

    // Runs on the audio queue. Cheap: one pass over ~512 frames.
    private func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var rmsSum: Float = 0
        var bassSq: Float = 0
        var count = 0
        let a: Float = 0.02 // one-pole low-pass ≈ 150 Hz at 48 kHz → kick & bass

        for buffer in buffers {
            guard let raw = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)

            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
            rmsSum += rms

            var lp = lowpass
            for i in 0..<n {
                lp += a * (samples[i] - lp)
                bassSq += lp * lp
            }
            lowpass = lp
            count += n
        }
        guard count > 0 else { return }
        let bass = sqrtf(bassSq / Float(count))
        let value = 0.65 * bass * 2.2 + 0.35 * (rmsSum / Float(max(1, buffers.count)))
        lock.withLock { $0 = value }
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr else { throw TapError.os("default output", err) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard err == noErr, let uid else { throw TapError.os("device uid", err) }
        return uid.takeRetainedValue() as String
    }

    enum TapError: Error {
        case os(String, OSStatus)
    }
}
