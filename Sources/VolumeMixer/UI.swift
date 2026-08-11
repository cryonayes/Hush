import SwiftUI
import CoreAudio

@MainActor
final class MixerModel: ObservableObject {
    @Published var apps: [AudioApp] = []
    @Published private(set) var volumes: [String: Float] = Settings.volumes
    @Published private(set) var muted: Set<String> = Settings.muted
    @Published var error: String?

    private var taps: [String: AppTap] = [:]
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        watchOutputDevice()
    }

    func volume(_ id: String) -> Float { volumes[id] ?? 1.0 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func setVolume(_ value: Float, for app: AudioApp) {
        volumes[app.id] = value
        Settings.volumes = volumes
        syncTaps()
    }

    func toggleMute(_ app: AudioApp) {
        muted.formSymmetricDifference([app.id])
        Settings.muted = muted
        syncTaps()
    }

    func refresh() {
        apps = AudioApp.all()
        syncTaps()
    }

    /// Single reconciler: brings every tap in line with the current volumes, process
    /// groups and output device. Covers first launch (saved volume, no tap yet), a
    /// helper appearing under an app you already turned down, and an output device
    /// switch — all of which are the same problem, "this tap no longer matches".
    private func syncTaps() {
        let currentUID = defaultOutputDeviceUID
        let alive = Set(apps.map(\.id))
        for id in Array(taps.keys) where !alive.contains(id) {
            taps[id]?.stop()
            taps[id] = nil
        }

        for app in apps {
            let gain = isMuted(app.id) ? 0 : volume(app.id)

            // At 100% and unmuted, drop the tap so the app keeps its native,
            // zero-latency path. Nothing to do for apps that aren't playing yet.
            guard gain != 1.0, app.isPlaying else {
                taps[app.id]?.stop()
                taps[app.id] = nil
                continue
            }

            if let tap = taps[app.id] {
                if tap.processIDs == app.processIDs && tap.outputUID == currentUID {
                    tap.gain = gain
                    continue
                }
                tap.stop()          // stale: new helper, or the user switched output
                taps[app.id] = nil
            }

            do {
                let tap = try AppTap(app: app)
                tap.gain = gain
                taps[app.id] = tap
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Rebuild taps when the user plugs in headphones — the aggregate device pins
    /// its output at creation, so an untouched tap would just go silent.
    private func watchOutputDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        // ponytail: never removed — this object lives as long as the process does.
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in self?.syncTaps() }
        }
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.apps.isEmpty {
                Text("No apps with audio").foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                row(app).opacity(app.isPlaying ? 1 : 0.55)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func row(_ app: AudioApp) -> some View {
        let volume = model.volume(app.id)
        let isMuted = model.isMuted(app.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let path = app.bundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 16, height: 16)
                }
                Text(app.name).lineLimit(1)
                Spacer()
                Button {
                    model.toggleMute(app)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isMuted ? Color.red : Color.secondary)

                Text("\(Int(volume * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            // Past 1.0 is amplification — something macOS itself won't do for you.
            Slider(value: Binding(get: { volume }, set: { model.setVolume($0, for: app) }),
                   in: 0...2)
                .disabled(isMuted)
        }
    }
}
