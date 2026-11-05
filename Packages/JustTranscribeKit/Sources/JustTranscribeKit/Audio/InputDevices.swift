import CoreAudio

/// An audio input device as Core Audio reports it; `uid` stays the same across reconnects and restarts.
public struct InputDevice: Identifiable, Hashable, Sendable {
    public let uid: String
    public let name: String
    public var id: String { uid }
}

/// The Mac's audio input devices, read from Core Audio on each call.
public enum InputDevices {
    /// Every connected device with at least one input channel.
    public static func all() -> [InputDevice] {
        deviceIDs().compactMap(device)
    }

    /// The name of the current macOS default input, or nil when there is none.
    public static func defaultName() -> String? {
        defaultDeviceID().flatMap { string($0, kAudioObjectPropertyName) }
    }

    /// The current macOS default input, or nil when there is none.
    static func defaultDeviceID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The connected input device with this UID, or nil when it is absent.
    static func deviceID(uid: String) -> AudioDeviceID? {
        deviceIDs().first { device($0)?.uid == uid }
    }

    /// Yields whenever a device is connected or removed, or the default input changes; listening stops
    /// when the consuming task ends.
    public static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let system = AudioObjectID(kAudioObjectSystemObject)
            var addresses = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice].map { address($0) }
            let block: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield() }
            for index in addresses.indices {
                AudioObjectAddPropertyListenerBlock(system, &addresses[index], .main, block)
            }
            let listener = Listener(addresses: addresses, block: block)
            continuation.onTermination = { _ in
                for var address in listener.addresses {
                    AudioObjectRemovePropertyListenerBlock(system, &address, .main, listener.block)
                }
            }
        }
    }

    // Unchecked: the block only yields to a Sendable continuation, and both fields are immutable.
    private struct Listener: @unchecked Sendable {
        let addresses: [AudioObjectPropertyAddress]
        let block: AudioObjectPropertyListenerBlock
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return InputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
