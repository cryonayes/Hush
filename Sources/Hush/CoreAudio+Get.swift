import CoreAudio
import AppKit

// Two generic readers cover every CoreAudio property we touch.

func caValue<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p) == noErr else { return nil }
    return p.pointee
}

func caArray<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let buf = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buf) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buf, count: count))
}

/// CFString properties come back +1 retained. Loading one through `caValue` would
/// copy it out with a second retain and leak the first, so strings get their own
/// reader that takes ownership explicitly.
func caString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var raw: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &raw) == noErr,
          let value = raw?.takeRetainedValue() else { return nil }
    return value as String
}

var defaultOutputDeviceUID: String? {
    guard let dev: AudioDeviceID = caValue(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyDefaultOutputDevice)
    else { return nil }
    return caString(dev, kAudioDevicePropertyDeviceUID)
}

/// One row in the mixer. An app can play through several processes (browser and
/// Electron audio lives in helper XPC processes), so a row owns a list of them
/// and gets a single tap covering all.
struct AudioApp: Identifiable, Hashable {
    let id: String              // parent bundle ID, or executable path when unbundled
    let name: String
    let bundlePath: String?
    let processIDs: [AudioObjectID]
    let isPlaying: Bool

    /// Every app with audio processes, helpers folded into their parent. Apps that
    /// aren't currently playing are included (so volumes can be pre-set) but only
    /// when they're a normal foreground app — that filters out the daemons and
    /// stale entries CoreAudio keeps in the process list.
    static func all() -> [AudioApp] {
        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))

        let ids: [AudioObjectID] = caArray(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyProcessObjectList)
        var seenPIDs = Set<pid_t>()

        let entries = ids.compactMap { objID -> (info: AppInfo, objID: AudioObjectID, playing: Bool)? in
            guard let pid: pid_t = caValue(objID, kAudioProcessPropertyPID),
                  pid != getpid() else { return nil }   // we play back the taps; don't tap ourselves
            seenPIDs.insert(pid)
            guard let info = appInfo(pid: pid) else { return nil }
            let running: UInt32 = caValue(objID, kAudioProcessPropertyIsRunningOutput) ?? 0
            let playing = running != 0
            guard playing || regular.contains(info.id) else { return nil }
            return (info, objID, playing)
        }
        infoCache = infoCache.filter { seenPIDs.contains($0.key) }

        return Dictionary(grouping: entries, by: \.info.id).map { id, group in
            AudioApp(id: id,
                     name: group[0].info.name,
                     bundlePath: group[0].info.bundlePath,
                     processIDs: group.map(\.objID).sorted(),
                     isPlaying: group.contains { $0.playing })
        }
        // Playing apps first, then alphabetical.
        .sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct AppInfo {
    let id: String
    let name: String
    let bundlePath: String?
}

/// ponytail: MainActor-only, so a plain dictionary is enough. Pruned each refresh.
private var infoCache: [pid_t: AppInfo] = [:]

/// `NSRunningApplication` only knows about foreground-registered apps, so audio
/// helpers come back nil. Their executables live *inside* the parent bundle
/// (…/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…), so the
/// first `.app` on the path identifies the app the user actually recognises.
private func appInfo(pid: pid_t) -> AppInfo? {
    if let cached = infoCache[pid] { return cached }

    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    let path = String(cString: buf)

    let info: AppInfo
    if let dotApp = path.range(of: ".app/") {
        let bundlePath = String(path[path.startIndex..<dotApp.lowerBound]) + ".app"
        let bundle = Bundle(path: bundlePath)
        info = AppInfo(id: bundle?.bundleIdentifier ?? bundlePath,
                       name: NSRunningApplication(processIdentifier: pid)?.localizedName
                           ?? FileManager.default.displayName(atPath: bundlePath),
                       bundlePath: bundlePath)
    } else {
        info = AppInfo(id: path, name: (path as NSString).lastPathComponent, bundlePath: nil)
    }
    infoCache[pid] = info
    return info
}
