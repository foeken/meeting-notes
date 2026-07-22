@preconcurrency import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneDeviceChoice: Identifiable, Equatable, Sendable {
  let id: String
  var name: String
  var isConnected: Bool
  var isSystemDefault: Bool
  var isExcluded: Bool
}

enum MicrophoneSettingsStore {
  private struct StoredDevice: Codable {
    let id: String
    let name: String
    let isExcluded: Bool
  }

  private static let useSystemDefaultKey = "microphone.useSystemDefault"
  private static let priorityKey = "microphone.priority"

  static func useSystemDefault(from defaults: UserDefaults = .standard) -> Bool {
    guard defaults.object(forKey: useSystemDefaultKey) != nil else { return true }
    return defaults.bool(forKey: useSystemDefaultKey)
  }

  static func saveUseSystemDefault(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: useSystemDefaultKey)
  }

  static func devices(from defaults: UserDefaults = .standard) -> [MicrophoneDeviceChoice] {
    let connected = MicrophoneDeviceProvider.connectedDevices()
    let connectedByID = Dictionary(uniqueKeysWithValues: connected.map { ($0.id, $0) })
    let stored = loadStored(from: defaults)
    var result = stored.map { saved in
      let current = connectedByID[saved.id]
      return MicrophoneDeviceChoice(
        id: saved.id,
        name: current?.name ?? saved.name,
        isConnected: current != nil,
        isSystemDefault: current?.isSystemDefault ?? false,
        isExcluded: saved.isExcluded
      )
    }
    let known = Set(result.map(\.id))
    result.append(contentsOf: connected.filter { !known.contains($0.id) })
    return result
  }

  static func saveDevices(
    _ devices: [MicrophoneDeviceChoice], to defaults: UserDefaults = .standard
  ) {
    let stored = devices.map { StoredDevice(id: $0.id, name: $0.name, isExcluded: $0.isExcluded) }
    if let data = try? JSONEncoder().encode(stored) {
      defaults.set(data, forKey: priorityKey)
    }
  }

  static func preferredDeviceUID(from defaults: UserDefaults = .standard) -> String? {
    guard !useSystemDefault(from: defaults) else { return nil }
    return devices(from: defaults).first { $0.isConnected && !$0.isExcluded }?.id
  }

  private static func loadStored(from defaults: UserDefaults) -> [StoredDevice] {
    guard let data = defaults.data(forKey: priorityKey),
      let stored = try? JSONDecoder().decode([StoredDevice].self, from: data)
    else { return [] }
    return stored
  }
}

enum MicrophoneDeviceProvider {
  static func connectedDevices() -> [MicrophoneDeviceChoice] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    )
    let defaultUID = defaultInputDeviceUID()
    var seen = Set<String>()
    return discovery.devices.compactMap { device in
      guard seen.insert(device.uniqueID).inserted else { return nil }
      return MicrophoneDeviceChoice(
        id: device.uniqueID,
        name: device.localizedName,
        isConnected: device.isConnected,
        isSystemDefault: device.uniqueID == defaultUID,
        isExcluded: false
      )
    }
    .sorted { lhs, rhs in
      if lhs.isSystemDefault != rhs.isSystemDefault { return lhs.isSystemDefault }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  static func audioDeviceID(forUID uidString: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = uidString as CFString
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var outputSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &uid) { qualifier in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<CFString>.size), qualifier,
        &outputSize, &deviceID
      )
    }
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func defaultInputDeviceUID() -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

    address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString?
    size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &uid) { pointer in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return uid as String?
  }
}
