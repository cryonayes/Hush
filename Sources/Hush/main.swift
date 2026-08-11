import AppKit
import CoreAudio
import AVFoundation

// Creates a real tap and prints its format — the only way to check the
// float32 guard in AppTap without dragging a slider. Needs the audio
// capture permission, so run the copy inside Hush.app.
if CommandLine.arguments.contains("--tapfmt") {
    guard let app = AudioApp.all().first(where: \.isPlaying) else {
        print("nothing playing"); exit(1)
    }
    let desc = CATapDescription(stereoMixdownOfProcesses: app.processIDs)
    desc.uuid = UUID()
    desc.isPrivate = true
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(desc, &tapID)
    guard status == noErr else { print("create tap failed: \(status)"); exit(1) }
    defer { AudioHardwareDestroyProcessTap(tapID) }

    guard let f: AudioStreamBasicDescription = caValue(tapID, kAudioTapPropertyFormat) else {
        print("no format property"); exit(1)
    }
    let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    print("\(app.name): \(f.mSampleRate)Hz \(f.mChannelsPerFrame)ch "
          + "\(f.mBitsPerChannel)-bit float=\(isFloat)")
    exit(f.mFormatID == kAudioFormatLinearPCM && isFloat && f.mBitsPerChannel == 32 ? 0 : 1)
}

// `--list` is the runnable check: no UI, no bundle, prints what CoreAudio sees.
if CommandLine.arguments.contains("--list") {
    let apps = AudioApp.all()
    for a in apps {
        print("\(a.isPlaying ? "▶" : " ") \(a.name)\t\(a.id)\t\(a.processIDs.count) process(es)")
    }
    let auth = AVCaptureDevice.authorizationStatus(for: .audio)
    print("\(apps.count) app(s), \(apps.filter(\.isPlaying).count) playing, "
          + "output device: \(defaultOutputDeviceUID ?? "none"), "
          + "audio capture: \(["notDetermined", "restricted", "denied", "authorized"][auth.rawValue])")
    exit(apps.isEmpty ? 1 : 0)
}

// Top-level code already runs on the main thread; the compiler just can't see it.
// The delegate is a global because NSApplication holds it weakly.
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
