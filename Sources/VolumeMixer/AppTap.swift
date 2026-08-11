import CoreAudio
import Accelerate

enum TapError: LocalizedError {
    case os(String, OSStatus)
    case noOutputDevice
    case unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .os(let what, let s): return "\(what) failed (\(s))"
        case .noOutputDevice: return "No default output device"
        case .unsupportedFormat: return "Tap is not 32-bit float PCM"
        }
    }
}

/// Taps one process, mutes its direct output, and replays it through the
/// default output device with `gain` applied. That multiply is the volume knob.
final class AppTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Target gain. 1.0 is untouched; above 1.0 amplifies. Written from the UI,
    /// read on the IO thread — ponytail: a lone Float store is atomic on arm64; if
    /// this ever grows into multi-field EQ state, swap in a lock-free double buffer.
    var gain: Float = 1.0

    /// Where the ramp starts each render — IO thread only.
    private var lastGain: Float = 1.0

    /// The processes this tap covers, so the model can spot a helper appearing later.
    let processIDs: [AudioObjectID]

    /// The device this tap was built against. Goes stale when the user switches output.
    let outputUID: String

    init(app: AudioApp) throws {
        guard let outputUID = defaultOutputDeviceUID else { throw TapError.noOutputDevice }
        self.outputUID = outputUID
        processIDs = app.processIDs

        let desc = CATapDescription(stereoMixdownOfProcesses: app.processIDs)
        desc.name = "VolumeMixer-\(app.id)"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped   // app's own path goes silent; we own playback now
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

        // render() does float32 arithmetic straight on the buffers. Verify that's
        // what we'll actually get rather than turning a surprise into noise.
        guard let format: AudioStreamBasicDescription = caValue(tapID, kAudioTapPropertyFormat),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { stop(); throw TapError.unsupportedFormat }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer \(app.id)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggID),
                  "AudioHardwareCreateAggregateDevice")

        let queue = DispatchQueue(label: "volumemixer.io.\(app.id)", qos: .userInteractive)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, input, _, output, _ in
            self?.render(input, output)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try check(AudioDeviceStart(aggID, procID), "AudioDeviceStart")
    }

    /// Copies the tapped audio to the output with the gain applied as a *ramp* from
    /// the previous buffer's value — a flat multiply would step on every slider
    /// move and click audibly.
    ///
    /// ponytail: tap-channels == device-channels, which is what a stereo mixdown
    /// into a normal output gives you. Extra output channels get silence; a real
    /// mixer would need a channel map here.
    private func render(_ input: UnsafePointer<AudioBufferList>,
                       _ output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let target = gain
        var lo: Float = -1, hi: Float = 1

        for i in 0..<outs.count {
            guard let dst = outs[i].mData else { continue }
            guard i < ins.count, let src = ins[i].mData else {
                memset(dst, 0, Int(outs[i].mDataByteSize)); continue
            }
            let bytes = min(ins[i].mDataByteSize, outs[i].mDataByteSize)
            let n = vDSP_Length(bytes / 4)
            guard n > 0 else { continue }

            var start = lastGain
            var step = (target - start) / Float(n)
            let d = dst.assumingMemoryBound(to: Float.self)
            vDSP_vrampmul(src.assumingMemoryBound(to: Float.self), 1, &start, &step, d, 1, n)
            // ponytail: hard clip. Only reachable above 100%; swap in a soft-knee
            // limiter if anyone actually mixes up there for long.
            if target > 1 || lastGain > 1 { vDSP_vclip(d, 1, &lo, &hi, d, 1, n) }

            if outs[i].mDataByteSize > bytes {
                memset(dst + Int(bytes), 0, Int(outs[i].mDataByteSize - bytes))
            }
        }
        lastGain = target
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { stop(); throw TapError.os(what, status) }
    }

    func stop() {
        if let procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
            self.procID = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
