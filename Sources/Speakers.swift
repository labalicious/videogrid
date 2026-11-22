import AppKit
import CoreAudio

/// Which speakers Video Grid plays through (Settings → Playback, or Playback → Sound Output).
/// By default sound follows macOS's output, which switches when you AirPlay or cast to a TV.
/// Choosing a device keeps Video Grid on it; while it's disconnected, sound follows macOS until it's back.
enum Speakers {
    struct Device { let id: AudioDeviceID; let uid: String; let name: String }

    /// Posted when the choice changes or speakers are connected or disconnected.
    static let changed = Notification.Name("VideoGridSpeakersChanged")

    /// The device string libVLC's macOS output takes: the chosen device's current ID if it's
    /// connected, otherwise "0" (whatever macOS is using).
    private(set) static var vlcDevice = "0"
    private static var watching = false

    /// Listens for speakers being connected or disconnected. Called once at launch.
    static func startWatching() {
        guard !watching else { return }
        watching = true
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            MainActor.assumeIsolated { refresh() }
        }
        refresh()
    }

    /// Works out the device to use now and tells every player.
    static func refresh() {
        if let uid = Prefs.speakerUID, let d = outputs().first(where: { $0.uid == uid }) {
            vlcDevice = String(d.id)
        } else {
            vlcDevice = "0"
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Every device that can play sound, as macOS lists it now.
    static func outputs() -> [Device] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), !isHidden(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}

/// Playback → Sound Output (rebuilt each time it opens) and Playback → Silence Others When Maximized.
final class AudioMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = AudioMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let follow = menu.addItem(withTitle: "Same as macOS", action: #selector(choose(_:)), keyEquivalent: "")
        follow.target = self
        follow.state = Prefs.speakerUID == nil ? .on : .off
        menu.addItem(.separator())
        let devices = Speakers.outputs()
        for d in devices {
            let item = menu.addItem(withTitle: d.name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uid
            item.state = d.uid == Prefs.speakerUID ? .on : .off
        }
        if let uid = Prefs.speakerUID, !devices.contains(where: { $0.uid == uid }) {
            let item = menu.addItem(withTitle: "\(Prefs.speakerName ?? "Chosen speakers") (not connected)",
                                    action: nil, keyEquivalent: "")
            item.state = .on
        }
    }

    @objc func choose(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        Prefs.setSpeakers(Speakers.outputs().first { $0.uid == uid })
    }

    @objc func toggleSilenceOthers(_ sender: NSMenuItem) {
        Prefs.muteOthersWhenMaximized.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSilenceOthers(_:)) {
            item.state = Prefs.muteOthersWhenMaximized ? .on : .off
        }
        return true
    }
}
