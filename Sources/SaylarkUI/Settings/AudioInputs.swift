import CoreAudio
import Foundation
import Observation
import SaylarkCore

/// Input devices for the microphone picker, read from Core Audio's device list. Listing devices
/// needs no permission and never opens the mic.
public struct AudioInput: Sendable, Hashable, Identifiable {
    public var uid: String
    public var name: String
    public var isBuiltIn = false
    public var id: String { uid }

    public init(uid: String, name: String, isBuiltIn: Bool = false) {
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

public enum AudioInputs {
    public static func list() -> [AudioInput] {
        devices().map { AudioInput(uid: $0.uid, name: $0.name, isBuiltIn: $0.transport == .builtIn) }
    }

    /// Every input device, with the transport the engine's mic policy needs.
    public static func devices() -> [MicDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = inputChannels(id)
            guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MicDevice(id: id, uid: uid, name: name, transport: transport(id), inputChannels: channels)
        }
    }

    /// The microphone Saylark will use now, by the same order the engine uses (`MicPolicy`): the
    /// pinned device, then USB, then built-in. Nil when there is no input at all.
    public static func current(pinnedUID: String?) -> MicDevice? {
        let all = devices()
        let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let outputName = output.flatMap { id in string(id, kAudioObjectPropertyName) }
        return MicPolicy.choose(from: all, pinnedUID: pinnedUID, outputID: output, outputName: outputName,
                                defaultInputID: defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    /// Calls `handler` on the main queue when devices are added or removed or a default changes.
    /// The returned token stops the watching when released.
    @MainActor public static func observe(_ handler: @escaping @MainActor () -> Void) -> DeviceObservation {
        DeviceObservation(handler)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func transport(_ id: AudioDeviceID) -> MicDevice.Transport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .other
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// How a device is named in the pill: "Samson Q2U Microphone" becomes "Samson Q2U mic", and a long
    /// name is cut so the sentence fits the pill.
    public static func pillName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        var suffix = ""
        for tail in [" Microphone", " Mic"] where n.hasSuffix(tail) && n.count > tail.count + 1 {
            n = String(n.dropLast(tail.count))
            suffix = " mic"
            break
        }
        let limit = 22
        if n.count > limit { n = String(n.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" }
        return n + suffix
    }
}

/// Core Audio listeners for the device list and the default devices, removed when released.
@MainActor public final class DeviceObservation {
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: DispatchWorkItem?

    init(_ handler: @escaping @MainActor () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            // A burst of changes (a Bluetooth connect fires several) collapses into one call.
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending?.cancel()
                    let item = DispatchWorkItem { MainActor.assumeIsolated { handler() } }
                    self.pending = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                }
            }
            if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr { listeners.append((address, block)) }
        }
    }

    func cancel() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(system, &a, .main, block)
        }
        listeners = []
        pending?.cancel()
    }
}

/// The microphone list Settings shows. It reads Core Audio off the main thread, on demand and
/// whenever devices change, so a mic plugged in after Settings was first opened still appears.
@MainActor @Observable public final class InputList {
    public private(set) var inputs: [AudioInput]
    @ObservationIgnored private var observation: DeviceObservation?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored public var onChange: (() -> Void)?

    /// A fixed list (renders, tests).
    public init(_ inputs: [AudioInput]) {
        self.inputs = inputs
    }

    /// The live list. Starts empty; call `refresh()`.
    public static func system() -> InputList {
        let list = InputList([])
        list.observation = AudioInputs.observe { [weak list] in list?.refresh() }
        return list
    }

    public func refresh() {
        generation += 1
        let mine = generation
        Task { [weak self] in
            let fresh = await Task.detached(priority: .userInitiated) { AudioInputs.list() }.value
            guard let self, mine == self.generation else { return }
            if fresh != self.inputs {
                self.inputs = fresh
                self.onChange?()
            }
        }
    }

    public var builtIn: AudioInput? { inputs.first(where: \.isBuiltIn) }
}
