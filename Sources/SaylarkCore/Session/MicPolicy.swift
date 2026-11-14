/// An audio input device as the engine sees it. Plain data, so the choice can be tested.
public struct MicDevice: Sendable, Equatable, Codable {
    public enum Transport: String, Sendable, Codable {
        case builtIn, usb, bluetooth, bluetoothLE, virtual, aggregate, other
        public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
    }

    /// Core Audio object ID. Changes across reboots and replugs; `uid` does not.
    public var id: UInt32
    public var uid: String
    public var name: String
    public var transport: Transport
    public var inputChannels: Int
    public var sampleRate: Double

    public init(id: UInt32, uid: String, name: String, transport: Transport, inputChannels: Int = 1, sampleRate: Double = 48_000) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannels = inputChannels
        self.sampleRate = sampleRate
    }
}

/// Picks the microphone: the pinned device, then USB, then built-in, then anything else.
/// Never a Bluetooth headset's mic while that headset is the output: opening it switches AirPods
/// to the call profile and ruins playback. Virtual and aggregate devices are only used when pinned.
/// Within one kind, the system default input wins (a USB webcam mic must not beat a USB desk mic
/// just by being listed first).
public enum MicPolicy {
    public static func choose(
        from devices: [MicDevice], pinnedUID: String?, outputID: UInt32?, outputName: String? = nil, defaultInputID: UInt32? = nil
    ) -> MicDevice? {
        let inputs = devices.filter { $0.inputChannels > 0 }
        func isPlayingHeadset(_ d: MicDevice) -> Bool {
            guard d.transport.isBluetooth else { return false }
            return d.id == outputID || (outputName != nil && d.name == outputName)
        }
        if let pinnedUID, let pinned = inputs.first(where: { $0.uid == pinnedUID }), !isPlayingHeadset(pinned) {
            return pinned
        }
        let order: [MicDevice.Transport] = [.usb, .builtIn, .other, .bluetooth, .bluetoothLE]
        for transport in order {
            let tier = inputs.filter { $0.transport == transport && !isPlayingHeadset($0) }
            if let d = tier.first(where: { $0.id == defaultInputID }) ?? tier.first { return d }
        }
        return nil
    }
}
