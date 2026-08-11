import CoreAudio
import Accelerate
import Synchronization
import AVFoundation

enum TapError: LocalizedError {
    case os(String, OSStatus)
    case noOutputDevice
    case unsupportedFormat
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Hush needs permission to capture audio."
        case .os(let what, let status):
            // Creating the tap is what triggers the system prompt, so a failure
            // here while permission is still undecided is almost always the user
            // not having answered it yet — say that instead of an OSStatus.
            if what.contains("ProcessTap"),
               AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                return "Allow audio capture when macOS asks, then try again."
            }
            return "\(what) failed (\(status))"
        case .noOutputDevice:
            return "No default output device"
        case .unsupportedFormat:
            return "Tap is not 32-bit float PCM"
        }
    }

    /// Whether the fix is a trip to System Settings, so the UI can offer the button.
    var isPermissionProblem: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// Taps one process, mutes its direct output, and replays it through the
/// default output device with `gain` applied. That multiply is the volume knob.
final class AppTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Target gain. 1.0 is untouched; above 1.0 amplifies. Written from the UI,
    /// read on the audio thread. Lock-free by necessity — a mutex on the audio
    /// thread is exactly the stall we're avoiding. Relaxed ordering is enough:
    /// there's nothing else to order against, and a gain arriving one buffer late
    /// is inaudible thanks to the ramp in render().
    private let atomicGain = Atomic<Float>(1.0)
    var gain: Float {
        get { atomicGain.load(ordering: .relaxed) }
        set { atomicGain.store(newValue, ordering: .relaxed) }
    }

    /// Where the ramp starts each render — audio thread only.
    private var lastGain: Float = 1.0

    /// The processes this tap covers, so the model can spot a helper appearing later.
    let processIDs: [AudioObjectID]

    /// The device this tap was built against. Goes stale when the user switches output.
    let outputUID: String

    /// Set when the output device is interleaved with a different channel count than
    /// the tap's stereo mixdown — HDMI and AV receivers land here. Holds the output's
    /// channel count; nil means the buffers line up and render() can copy straight.
    private var interleavedOutputChannels: Int?
    private var tapChannels = 2

    init(app: AudioApp) throws {
        // Checking the status beats mapping OSStatus codes: a denied tap and a
        // failed-for-other-reasons tap are indistinguishable from the return value.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw TapError.permissionDenied
        default: break
        }
        guard let outputUID = defaultOutputDeviceUID else { throw TapError.noOutputDevice }
        self.outputUID = outputUID
        processIDs = app.processIDs

        let desc = CATapDescription(stereoMixdownOfProcesses: app.processIDs)
        desc.name = "Hush-\(app.id)"
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
        tapChannels = Int(format.mChannelsPerFrame)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hush \(app.id)",
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

        // nil queue == invoked directly on CoreAudio's real-time thread. Passing a
        // dispatch queue makes that thread hop synchronously onto ours every buffer:
        // extra latency, jitter, and a priority inversion under load.
        //
        // That puts render() on the audio thread, so it must not allocate, lock, or
        // touch ARC. `unowned(unsafe)` avoids the weak-table lock a `weak` capture
        // would take; it's safe because stop() runs first thing in deinit and
        // AudioDeviceStop blocks until any in-flight render() has returned.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [unowned(unsafe) self] _, input, _, output, _ in
            self.render(input, output)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        // A 5.1 output hands us one interleaved buffer of 6 channels. Copying a
        // stereo buffer into the front of it would scatter L/R across the wrong
        // speakers, so that case needs a strided per-channel copy instead.
        if let out: AudioStreamBasicDescription = caValue(aggID, kAudioDevicePropertyStreamFormat,
                                                          scope: kAudioObjectPropertyScopeOutput),
           out.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
           Int(out.mChannelsPerFrame) != tapChannels {
            interleavedOutputChannels = Int(out.mChannelsPerFrame)
        }

        try check(AudioDeviceStart(aggID, procID), "AudioDeviceStart")
    }

    /// Copies the tapped audio to the output with the gain applied as a *ramp* from
    /// the previous buffer's value — a flat multiply would step on every slider
    /// move and click audibly.
    ///
    private func render(_ input: UnsafePointer<AudioBufferList>,
                       _ output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let target = gain
        var lo: Float = -1, hi: Float = 1

        if let outChannels = interleavedOutputChannels {
            renderStrided(ins, outs, target: target, outChannels: outChannels, lo: &lo, hi: &hi)
            lastGain = target
            return
        }

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

    /// Stereo into a wider interleaved output: place the tap's channels on the
    /// output's first channels one at a time, and silence the rest. Without this,
    /// 5.1 output gets stereo smeared across the wrong speakers at the wrong rate.
    private func renderStrided(_ ins: UnsafeMutableAudioBufferListPointer,
                               _ outs: UnsafeMutableAudioBufferListPointer,
                               target: Float, outChannels: Int,
                               lo: inout Float, hi: inout Float) {
        guard let srcRaw = ins.count > 0 ? ins[0].mData : nil,
              let dstRaw = outs.count > 0 ? outs[0].mData : nil else { return }
        let src = srcRaw.assumingMemoryBound(to: Float.self)
        let dst = dstRaw.assumingMemoryBound(to: Float.self)

        let frames = min(Int(ins[0].mDataByteSize) / (4 * tapChannels),
                         Int(outs[0].mDataByteSize) / (4 * outChannels))
        guard frames > 0 else { return }
        let n = vDSP_Length(frames)

        for ch in 0..<min(tapChannels, outChannels) {
            var start = lastGain                      // same ramp on every channel
            var step = (target - start) / Float(frames)
            vDSP_vrampmul(src + ch, vDSP_Stride(tapChannels), &start, &step,
                          dst + ch, vDSP_Stride(outChannels), n)
            if target > 1 || lastGain > 1 {
                vDSP_vclip(dst + ch, vDSP_Stride(outChannels), &lo, &hi,
                           dst + ch, vDSP_Stride(outChannels), n)
            }
        }
        for ch in tapChannels..<outChannels {
            vDSP_vclr(dst + ch, vDSP_Stride(outChannels), n)
        }
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
