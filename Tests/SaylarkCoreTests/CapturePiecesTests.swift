import Foundation
import Testing
@testable import SaylarkCore

@Suite struct MicPolicyTests {
    let builtIn = MicDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    let usb = MicDevice(id: 2, uid: "AppleUSBAudioEngine:Samson:Q2U", name: "Samson Q2U Microphone", transport: .usb)
    let airpods = MicDevice(id: 3, uid: "AA-BB:input", name: "AirPods Pro", transport: .bluetooth)
    let virtual = MicDevice(id: 4, uid: "BlackHole2ch", name: "BlackHole 2ch", transport: .virtual, inputChannels: 2)
    let speakers = MicDevice(id: 5, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn, inputChannels: 0)

    @Test func usbBeatsBuiltIn() {
        #expect(MicPolicy.choose(from: [builtIn, usb, airpods], pinnedUID: nil, outputID: 5) == usb)
    }

    @Test func defaultInputWinsWithinKind() {
        let webcam = MicDevice(id: 6, uid: "AppleUSBAudioEngine:C270", name: "C270 HD WEBCAM", transport: .usb)
        #expect(MicPolicy.choose(from: [webcam, usb, builtIn], pinnedUID: nil, outputID: 5, defaultInputID: usb.id) == usb)
        // The default being built-in doesn't beat USB: kind order comes first.
        #expect(MicPolicy.choose(from: [webcam, usb, builtIn], pinnedUID: nil, outputID: 5, defaultInputID: builtIn.id) == webcam)
    }

    @Test func builtInWhenNoUSB() {
        #expect(MicPolicy.choose(from: [airpods, builtIn], pinnedUID: nil, outputID: 5) == builtIn)
    }

    @Test func pinnedWins() {
        #expect(MicPolicy.choose(from: [builtIn, usb], pinnedUID: builtIn.uid, outputID: nil) == builtIn)
    }

    @Test func missingPinFallsBack() {
        #expect(MicPolicy.choose(from: [builtIn, usb], pinnedUID: "gone", outputID: nil) == usb)
    }

    @Test func neverAirPodsMicWhileTheyPlay() {
        #expect(MicPolicy.choose(from: [airpods, builtIn], pinnedUID: airpods.uid, outputID: airpods.id) == builtIn)
        #expect(MicPolicy.choose(from: [airpods], pinnedUID: nil, outputID: airpods.id) == nil)
        // Matched by name when the output is a separate device object.
        #expect(MicPolicy.choose(from: [airpods], pinnedUID: nil, outputID: 99, outputName: "AirPods Pro") == nil)
    }

    @Test func airPodsMicWhenSomethingElsePlays() {
        #expect(MicPolicy.choose(from: [airpods], pinnedUID: nil, outputID: 5) == airpods)
        #expect(MicPolicy.choose(from: [airpods, builtIn], pinnedUID: airpods.uid, outputID: 5) == airpods)
    }

    @Test func virtualOnlyWhenPinned() {
        #expect(MicPolicy.choose(from: [virtual], pinnedUID: nil, outputID: 5) == nil)
        #expect(MicPolicy.choose(from: [virtual, builtIn], pinnedUID: virtual.uid, outputID: 5) == virtual)
    }

    @Test func outputOnlyDevicesSkipped() {
        #expect(MicPolicy.choose(from: [speakers], pinnedUID: speakers.uid, outputID: 5) == nil)
    }
}

@Suite struct VoiceLevelMeterTests {
    @Test func emitsAt120HzExactly() {
        var meter = VoiceLevelMeter()
        var levels: [VoiceLevel] = []
        // 3 s in uneven chunks.
        var fed = 0
        let sizes = [100, 333, 1600, 7, 4096]
        var k = 0
        while fed < 48_000 {
            let n = min(sizes[k % sizes.count], 48_000 - fed)
            levels += meter.add([Float](repeating: 0.1, count: n))
            fed += n; k += 1
        }
        #expect(levels.count == 360)
        #expect(abs(levels.last!.time - 3) < 1e-9)
    }

    @Test func dBValues() {
        var meter = VoiceLevelMeter()
        let sine = (0..<1600).map { Float(0.5 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        let levels = meter.add(sine)
        let l = levels[5]
        #expect(abs(l.peakDB - (-6.02)) < 0.2)
        #expect(abs(l.rmsDB - (-9.03)) < 0.5)
        var silent = VoiceLevelMeter()
        #expect(silent.add([Float](repeating: 0, count: 200))[0].peakDB == VoiceLevelMeter.floorDB)
    }
}

@Suite struct PreRollRingTests {
    @Test func keepsNewestInOrder() {
        var ring = PreRollRing(capacity: 5)
        ring.add([1, 2, 3])
        #expect(ring.latest(10) == [1, 2, 3])
        ring.add([4, 5, 6, 7])
        #expect(ring.latest(5) == [3, 4, 5, 6, 7])
        #expect(ring.latest(2) == [6, 7])
        ring.add([8, 9, 10, 11, 12, 13])
        #expect(ring.latest(5) == [9, 10, 11, 12, 13])
        ring.clear()
        #expect(ring.latest(5).isEmpty)
    }
}
