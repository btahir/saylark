import AudioToolbox
import CoreAudio
import Foundation
import SaylarkCore
import Synchronization

/// The real microphone: an AUHAL unit bound to one device, so the system default input is never
/// changed (VoiceInk's pattern). The real-time callback only renders into a preallocated buffer and
/// copies into a lock-free ring; a worker drains the ring and calls `onChunk`.
///
/// Why AUHAL over AVAudioEngine: binding a device needs `kAudioOutputUnitProperty_CurrentDevice`
/// either way (AVAudioEngine's input node follows the system default otherwise), AUHAL starts only
/// the input side, and it never reconfigures on unrelated output changes
/// (`AVAudioEngineConfigurationChange` restarts the whole graph when AirPods connect).
public final class HALAudioSource: AudioSource, @unchecked Sendable {
    public let name: String
    public private(set) var sampleRate: Double
    public let device: MicDevice

    private var unit: AudioUnit?
    private let ring: SampleRing
    private let render: RenderContext
    private let worker = DispatchQueue(label: "saylark.capture", qos: .userInitiated)
    /// Marks `worker`, so `stop()` and `flush()` know when they already run on it.
    private static let onWorker = DispatchSpecificKey<Bool>()
    private var drain: (any DispatchSourceUserDataAdd)?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private let running = Atomic<Bool>(false)
    /// Guards `unit`, `drain`, `aliveListener` and `deliver` between start, stop and flush, which may
    /// run on different threads (control queue, worker, deinit).
    private let lifecycle = NSLock()
    private var deliver: (@Sendable ([Float]) -> Void)?

    public init(device: MicDevice) {
        self.device = device
        self.name = device.name
        self.sampleRate = device.sampleRate
        // Two seconds of headroom at the device rate: the worker drains every callback (~10 ms).
        ring = SampleRing(capacity: Int(max(device.sampleRate, 16_000) * 2))
        render = RenderContext(maxFrames: 8192)
        worker.setSpecific(key: Self.onWorker, value: true)
    }

    deinit {
        stop()
        render.deallocate()
    }

    public func start(onChunk: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (AudioSourceFailure) -> Void) throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !running.load(ordering: .acquiring) else { return }
        ring.reset()
        deliver = onChunk
        let drain = DispatchSource.makeUserDataAddSource(queue: worker)
        drain.setEventHandler { [ring] in
            let chunk = ring.drain()
            if !chunk.isEmpty { onChunk(chunk) }
        }
        drain.resume()
        self.drain = drain
        render.signal = drain
        render.ring = ring

        do {
            try makeUnit()
        } catch {
            drain.cancel()
            self.drain = nil
            throw error
        }
        watchAlive(onFailure: onFailure)
        running.store(true, ordering: .releasing)
    }

    public func flush() {
        guard running.load(ordering: .acquiring) else { return }
        let ring = self.ring
        let deliver = lifecycle.withLock { self.deliver }
        let work = {
            let chunk = ring.drain()
            if !chunk.isEmpty { deliver?(chunk) }
        }
        if DispatchQueue.getSpecific(key: Self.onWorker) == true { work() } else { worker.sync(execute: work) }
    }

    /// Safe from any thread. On the worker queue itself (an unplug reported by the alive listener)
    /// it must not sync onto the worker: libdispatch traps on a sync to the current queue. There it
    /// drains inline instead, and the listener is removed from another queue (not from inside its
    /// own callback).
    public func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let onWorker = DispatchQueue.getSpecific(key: Self.onWorker) == true
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        render.unit = nil
        if let block = aliveListener {
            let id = device.id, worker = self.worker
            let remove = {
                var addr = AudioDevices.address(kAudioDevicePropertyDeviceIsAlive)
                AudioObjectRemovePropertyListenerBlock(id, &addr, worker, block)
            }
            if onWorker { DispatchQueue.global(qos: .utility).async(execute: remove) } else { remove() }
            aliveListener = nil
        }
        // Deliver anything still in the ring, then stop the drain.
        if let drain {
            let ring = self.ring, deliver = self.deliver
            let work = {
                let chunk = ring.drain()
                if !chunk.isEmpty { deliver?(chunk) }
            }
            if onWorker { work() } else { worker.sync(execute: work) }
            drain.cancel()
        }
        drain = nil
        render.signal = nil
        deliver = nil
    }

    private func makeUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw AudioSourceFailure.startFailed(status: -1, step: "find AUHAL") }
        var maybeUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &maybeUnit), "new AUHAL")
        guard let unit = maybeUnit else { throw AudioSourceFailure.startFailed(status: -1, step: "new AUHAL") }
        self.unit = unit
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var one: UInt32 = 1, zero: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32), "disable output")
        var deviceID = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "bind device")

        // Hardware format on the input side of element 1 gives the device rate.
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read format")
        if hw.mSampleRate > 0 { sampleRate = hw.mSampleRate }

        // Client format: mono Float32 at the device rate (AUHAL does not resample input).
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set format")
        if hw.mChannelsPerFrame > 1 {
            var map: [Int32] = [0]  // take the first channel
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, UInt32(MemoryLayout<Int32>.size)), "channel map")
        }
        var maxFrames = UInt32(render.maxFrames)
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)

        render.unit = unit
        var callback = AURenderCallbackStruct(inputProc: halInputCallback, inputProcRefCon: Unmanaged.passUnretained(render).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        try check(AudioUnitInitialize(unit), "initialize")
        try check(AudioOutputUnitStart(unit), "start")
    }

    private func watchAlive(onFailure: @escaping @Sendable (AudioSourceFailure) -> Void) {
        var addr = AudioDevices.address(kAudioDevicePropertyDeviceIsAlive)
        let id = device.id, name = device.name
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running.load(ordering: .acquiring), !AudioDevices.isAlive(id) else { return }
            onFailure(.deviceLost(name: name))
        }
        if AudioObjectAddPropertyListenerBlock(id, &addr, worker, block) == noErr { aliveListener = block }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr {
            if let unit { AudioComponentInstanceDispose(unit) }
            unit = nil
            throw AudioSourceFailure.startFailed(status: status, step: step)
        }
    }
}

/// Everything the real-time callback touches, allocated up front.
final class RenderContext: @unchecked Sendable {
    let maxFrames: Int
    let buffer: UnsafeMutablePointer<Float>
    let list: UnsafeMutablePointer<AudioBufferList>
    var unit: AudioUnit?
    var ring: SampleRing?
    var signal: (any DispatchSourceUserDataAdd)?

    init(maxFrames: Int) {
        self.maxFrames = maxFrames
        buffer = .allocate(capacity: maxFrames)
        list = .allocate(capacity: 1)
        list.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: UnsafeMutableRawPointer(buffer)))
    }

    func deallocate() {
        buffer.deallocate()
        list.deallocate()
    }
}

/// Real-time thread: render the input, copy to the ring, poke the worker. No allocation, no locks.
private func halInputCallback(
    refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timeStamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = ctx.unit, let ring = ctx.ring, Int(frames) <= ctx.maxFrames else { return noErr }
    ctx.list.pointee.mBuffers.mDataByteSize = frames * 4
    ctx.list.pointee.mBuffers.mData = UnsafeMutableRawPointer(ctx.buffer)
    let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, ctx.list)
    guard status == noErr else { return status }
    ring.write(ctx.buffer, count: Int(frames))
    ctx.signal?.add(data: 1)
    return noErr
}

/// Single-producer, single-consumer ring of samples. The audio thread writes, the worker drains.
final class SampleRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)  // total written
    private let tail = Atomic<Int>(0)  // total read

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    func reset() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Producer. Drops the oldest audio if the consumer fell more than `capacity` behind.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let h = head.load(ordering: .relaxed)
        for i in 0..<count { storage[(h + i) % capacity] = src[i] }
        head.store(h + count, ordering: .releasing)
    }

    /// Consumer.
    func drain() -> [Float] {
        let h = head.load(ordering: .acquiring)
        var t = tail.load(ordering: .relaxed)
        if h - t > capacity { t = h - capacity }
        let n = h - t
        guard n > 0 else { return [] }
        let out = [Float](unsafeUninitializedCapacity: n) { buf, count in
            for i in 0..<n { buf[i] = storage[(t + i) % capacity] }
            count = n
        }
        tail.store(h, ordering: .releasing)
        return out
    }
}
