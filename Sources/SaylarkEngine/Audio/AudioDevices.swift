import CoreAudio
import Foundation
import SaylarkCore

/// Core Audio device lookups. Reading device properties opens nothing and needs no permission.
public enum AudioDevices {
    /// Every device with at least one input channel.
    public static func inputs() -> [MicDevice] {
        allDeviceIDs().compactMap(device(_:)).filter { $0.inputChannels > 0 }
    }

    public static func device(_ id: AudioObjectID) -> MicDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? uid
        let transport: MicDevice.Transport = switch scalar(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth: .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: .bluetoothLE
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .other
        }
        let rate = scalar(id, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 48_000
        return MicDevice(id: id, uid: uid, name: name, transport: transport, inputChannels: inputChannels(id), sampleRate: rate)
    }

    public static func defaultOutput() -> MicDevice? {
        scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)).flatMap(device(_:))
    }

    public static func defaultInput() -> MicDevice? {
        scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0)).flatMap(device(_:))
    }

    /// The device the policy picks now.
    public static func choose(pinnedUID: String?) -> MicDevice? {
        let output = defaultOutput()
        return MicPolicy.choose(from: inputs(), pinnedUID: pinnedUID, outputID: output?.id, outputName: output?.name, defaultInputID: defaultInput()?.id)
    }

    public static func isAlive(_ id: AudioObjectID) -> Bool {
        (scalar(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) ?? 0) != 0
    }

    // MARK: - Property helpers

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T) -> T? {
        var addr = address(selector)
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func inputChannels(_ id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Watches the device list and the default devices. Bursts (a Bluetooth connect fires several
/// events) are debounced into one call on `queue`.
public final class AudioDeviceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "saylark.audio-devices")
    private let onChange: @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioDevices.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
            if AudioObjectAddPropertyListenerBlock(system, &addr, queue, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    deinit {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(system, &a, queue, block)
        }
    }
}
