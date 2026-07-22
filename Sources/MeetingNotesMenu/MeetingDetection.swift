import AppKit
import CoreAudio
import CoreMediaIO
import Foundation

enum MeetingDetectionSettingsStore {
  private static let key = "meetingDetectionEnabled"

  static func load(from defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
  }

  static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: key)
  }
}

struct MeetingAppDetector {
  struct RunningApp: Equatable {
    let bundleIdentifier: String
    let isActive: Bool
  }

  private static let dedicatedApps: [String: String] = [
    "us.zoom.xos": "Zoom",
    "us.zoom.ZoomPhone": "Zoom",
    "com.microsoft.teams2": "Teams",
    "com.microsoft.teams": "Teams",
    "com.apple.FaceTime": "FaceTime",
    "com.tinyspeck.slackmacgap": "Slack",
    "net.whatsapp.WhatsApp": "WhatsApp",
  ]

  private static let browserApps: [String: String] = [
    "com.google.Chrome": "Chrome"
  ]

  static func detectedApp(cameraActive: Bool, microphoneActive: Bool, apps: [RunningApp]) -> String? {
    guard cameraActive, microphoneActive else { return nil }

    if let active = apps.first(where: { app in
      Self.dedicatedApps[app.bundleIdentifier] != nil && app.isActive
    }) {
      return Self.dedicatedApps[active.bundleIdentifier]
    }
    if let browser = apps.first(where: { app in
      Self.browserApps[app.bundleIdentifier] != nil && app.isActive
    }) {
      return Self.browserApps[browser.bundleIdentifier]
    }
    if let dedicated = apps.first(where: { Self.dedicatedApps[$0.bundleIdentifier] != nil }) {
      return Self.dedicatedApps[dedicated.bundleIdentifier]
    }
    return nil
  }
}

private typealias CameraListenerBlock = @convention(block) (
  UInt32, UnsafePointer<CMIOObjectPropertyAddress>?
) -> Void

@MainActor
final class MeetingActivityMonitor {
  var onDetectedAppChanged: ((String?) -> Void)?

  private var cameraListeners: [CMIOObjectID: CameraListenerBlock] = [:]
  private var cameraDeviceListListener: CameraListenerBlock?
  private var microphoneDeviceID: AudioDeviceID = 0
  private var microphoneListener: AudioObjectPropertyListenerBlock?
  private var defaultMicrophoneListener: AudioObjectPropertyListenerBlock?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var lastDetectedApp: String?
  private var isStarted = false

  func start() {
    guard !isStarted else { return }
    isStarted = true
    installCameraDeviceListListener()
    refreshCameraListeners()
    installMicrophoneListener()
    installDefaultMicrophoneListener()
    installWorkspaceObservers()
    evaluate()
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    removeCameraListeners()
    removeCameraDeviceListListener()
    removeMicrophoneListener()
    removeDefaultMicrophoneListener()
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach(center.removeObserver)
    workspaceObservers.removeAll()
    publish(nil)
  }

  private func installWorkspaceObservers() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.evaluate() }
        })
    }
  }

  private func installCameraDeviceListListener() {
    let block: CameraListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refreshCameraListeners() }
    }
    cameraDeviceListListener = block
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    CMIOObjectAddPropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject), &address, nil, block)
  }

  private func removeCameraDeviceListListener() {
    guard let block = cameraDeviceListListener else { return }
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    CMIOObjectRemovePropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject), &address, nil, block)
    cameraDeviceListListener = nil
  }

  private func refreshCameraListeners() {
    let deviceIDs = Set(cameraDeviceIDs())
    for (deviceID, block) in cameraListeners where !deviceIDs.contains(deviceID) {
      removeCameraListener(deviceID: deviceID, block: block)
      cameraListeners.removeValue(forKey: deviceID)
    }
    for deviceID in deviceIDs where cameraListeners[deviceID] == nil {
      let block: CameraListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.evaluate() }
      }
      cameraListeners[deviceID] = block
      var address = cameraRunningAddress
      CMIOObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
    }
    evaluate()
  }

  private func removeCameraListeners() {
    for (deviceID, block) in cameraListeners {
      removeCameraListener(deviceID: deviceID, block: block)
    }
    cameraListeners.removeAll()
  }

  private func removeCameraListener(deviceID: CMIOObjectID, block: @escaping CameraListenerBlock) {
    var address = cameraRunningAddress
    CMIOObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
  }

  private var cameraRunningAddress: CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
  }

  private func cameraDeviceIDs() -> [CMIOObjectID] {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(
      CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else { return [] }
    var devices = [CMIOObjectID](
      repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
    var used = dataSize
    guard CMIOObjectGetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &devices) == noErr
    else { return [] }
    return devices
  }

  private func isCameraActive() -> Bool {
    cameraListeners.keys.contains { deviceID in
      var address = cameraRunningAddress
      var running: UInt32 = 0
      var used = UInt32(MemoryLayout<UInt32>.size)
      return CMIOObjectGetPropertyData(
        deviceID, &address, 0, nil, used, &used, &running) == noErr && running != 0
    }
  }

  private func installMicrophoneListener() {
    removeMicrophoneListener()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0
    else { return }
    microphoneDeviceID = deviceID
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.evaluate() }
    }
    microphoneListener = block
    var runningAddress = microphoneRunningAddress
    AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, nil, block)
  }

  private func removeMicrophoneListener() {
    guard microphoneDeviceID != 0, let block = microphoneListener else { return }
    var address = microphoneRunningAddress
    AudioObjectRemovePropertyListenerBlock(microphoneDeviceID, &address, nil, block)
    microphoneDeviceID = 0
    microphoneListener = nil
  }

  private func installDefaultMicrophoneListener() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.installMicrophoneListener()
        self?.evaluate()
      }
    }
    defaultMicrophoneListener = block
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
  }

  private func removeDefaultMicrophoneListener() {
    guard let block = defaultMicrophoneListener else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    defaultMicrophoneListener = nil
  }

  private var microphoneRunningAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private func isMicrophoneActive() -> Bool {
    guard microphoneDeviceID != 0 else { return false }
    var address = microphoneRunningAddress
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(
      microphoneDeviceID, &address, 0, nil, &size, &running) == noErr && running != 0
  }

  private func evaluate() {
    guard isStarted else { return }
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> MeetingAppDetector.RunningApp? in
      guard let bundleIdentifier = app.bundleIdentifier else { return nil }
      return .init(bundleIdentifier: bundleIdentifier, isActive: app.isActive)
    }
    publish(MeetingAppDetector.detectedApp(
      cameraActive: isCameraActive(), microphoneActive: isMicrophoneActive(), apps: apps))
  }

  private func publish(_ app: String?) {
    guard app != lastDetectedApp else { return }
    lastDetectedApp = app
    onDetectedAppChanged?(app)
  }
}
