import Foundation
import Testing
@testable import SaylarkUI
import SaylarkCore

@Suite struct LivePillSessionTests {
    @Test func engineEventsDriveThePill() {
        var s = LivePillSession()
        s.handle(.pill(.listen), at: 0)
        s.handle(.level(VoiceLevel(time: 0.01, peakDB: -20, rmsDB: -30)), at: 0.01)
        let f = s.frame(at: 0.02)
        #expect(f.state.phase == .listening)
        #expect(abs(Double(f.rms ?? 0) - pow(10, -30.0 / 20)) < 1e-6)
        s.handle(.pill(.words(["hello", "there"])), at: 0.5)
        #expect(s.state.words == ["hello", "there"])
        s.handle(.pill(.finish(.inserted)), at: 1)
        #expect(s.frame(at: 1.01).rms == nil)
        _ = s.frame(at: 1.5)
        #expect(s.state.phase == .hidden)
    }

    @Test func stalledLevelsCountAsNoSignal() {
        var s = LivePillSession()
        s.handle(.pill(.listen), at: 0)
        s.handle(.level(VoiceLevel(time: 0, peakDB: -20, rmsDB: -30)), at: 0)
        #expect(s.frame(at: 0.1).rms ?? 0 > 0)
        // The engine stops sending levels: silence after `staleAfter`, no signal after 2 s.
        #expect(s.frame(at: 0.5).rms == 0)
        #expect(!s.frame(at: 1.5).state.noSignal)
        #expect(s.frame(at: 2.2).state.noSignal)
    }

    @Test func savedReturnsTheRecord() {
        var s = LivePillSession()
        let r = SampleTakes.records()[0]
        #expect(s.handle(.saved(r), at: 0) == r)
    }
}

@MainActor @Suite struct LibraryStatsTests {
    @Test func statsOverSampleTakes() {
        let now = AppModelTests.noon()
        let s = LibraryStats.compute(SampleTakes.records(now: now), now: now)
        #expect(s.wordsToday > 0 && s.wordsThisWeek >= s.wordsToday)
        #expect(s.takesToday > 0 && s.minutesToday > 0)
        #expect((s.medianTimeToTextMs ?? 0) > 30)
    }

    @Test func cancelledAndEmptyTakesDoNotCount() {
        let now = AppModelTests.noon()
        var records = SampleTakes.records(now: now)
        let all = LibraryStats.compute(records, now: now)
        records[0].outcome = .cancelled
        let fewer = LibraryStats.compute(records, now: now)
        #expect(fewer.wordsToday == all.wordsToday - records[0].cleanText.split(separator: " ").count)
        #expect(fewer.takesToday == all.takesToday - 1)
    }

    @Test func medianOfEvenAndOdd() {
        #expect(LibraryStats.median([3, 1, 2]) == 2)
        #expect(LibraryStats.median([4, 1, 3, 2]) == 2.5)
        #expect(LibraryStats.median([]) == nil)
    }
}

@Suite struct EscShakeTests {
    @Test func firstSwingIsAboutSixPoints() {
        var s = Spring(0, params: PillSprings.shake)
        s.velocity = -PillSprings.shakeKick
        var peak = 0.0
        for _ in 0..<60 { s.step(1.0 / 120); peak = max(peak, abs(s.value)) }
        #expect(peak > 5.4 && peak < 6.6, "first swing \(peak) pt")
    }
}

@MainActor @Suite struct AppModelTests {
    @Test func settingsDefaultsFollowOwnerDecisions() {
        let d = UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(s.voiceVisual == .seeds && !s.liveWords && s.accent == .ember && !s.sounds && s.triggerKey == .fn)
        s.voiceVisual = .wave
        s.liveWords = true
        #expect(AppSettings(defaults: d).voiceVisual == .wave)
        #expect(AppSettings(defaults: d).liveWords)
        #expect(AppSettings(defaults: d).pillTheme.liveWords)
    }

    /// Shadow mode is gone. A user who had it saved ends up pasting, and the old key is dropped.
    @Test func savedShadowModeIsDropped() {
        let d = UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")!
        d.set("shadow", forKey: "mode")
        _ = AppSettings(defaults: d)
        #expect(d.object(forKey: "mode") == nil)
    }

    @Test func onboardingAsksForEveryPermission() {
        let m = OnboardingModel(permissions: FakePermissions(), step: .welcome)
        #expect(m.steps == OnboardingModel.Step.allCases)
        #expect(FakePermissions().required == Permission.allCases)
    }

    @Test func onboardingMovesOnWhenPermissionArrives() async throws {
        let perms = FakePermissions([.microphone: .notDetermined])
        let m = OnboardingModel(permissions: perms, step: .microphone)
        #expect(m.status(.microphone) == .notDetermined)
        perms.states[.microphone] = .granted
        m.refresh()
        // The model moves on 700 ms after the permission arrives. Poll instead of sleeping a fixed
        // time, so a busy machine cannot make this miss.
        for _ in 0..<100 where m.step != .keyboard { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.step == .keyboard)
    }

    /// A fixed clock at noon, so the sample takes (the newest is 4 minutes old) never straddle midnight.
    /// The old test used the wall clock and failed in the first minutes after midnight, and waited a
    /// fixed 100 ms for the search, which a busy machine can miss.
    static func noon() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    @Test func libraryGroupsByDayAndSearches() async throws {
        let now = Self.noon()
        let model = LibraryModel(history: FakeHistory(SampleTakes.records(now: now)))
        model.now = { now }
        await model.load()
        #expect(model.days.first?.title == "Today")
        model.query = "vercel"
        await model.settle()
        #expect(model.shown.count == 1)
        model.query = ""
        #expect(model.shown.count == model.all.count)
    }

    @Test func libraryDayTitlesFollowTheClockAtMidnight() async throws {
        // Two minutes past midnight: the newest sample (4 minutes old) belongs to yesterday.
        let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(120)
        let model = LibraryModel(history: FakeHistory(SampleTakes.records(now: midnight)))
        model.now = { midnight }
        await model.load()
        #expect(model.days.first?.title == "Yesterday")
        #expect(!model.days.contains { $0.title == "Today" })
    }

    @Test func libraryStatsFollowSavesAndDeletes() async throws {
        let now = Self.noon()
        let model = LibraryModel(history: FakeHistory(SampleTakes.records(now: now)))
        model.now = { now }
        await model.load()
        let before = model.stats.wordsToday
        #expect(before > 0)
        var extra = SampleTakes.records(now: now)[0]
        extra.id = UUID()
        extra.startedAt = now.addingTimeInterval(-30)
        extra.cleanText = "one two three four five"
        model.upsert(extra)
        await model.settle()
        #expect(model.stats.wordsToday == before + 5)
        model.delete(extra)
        await model.settle()
        #expect(model.stats.wordsToday == before)
    }

    @Test func fakeEngineTakeEndsSaved() async throws {
        let engine = FakeEngine()
        var session = LivePillSession()
        engine.playTake()
        var saved: DictationRecord?
        var t = 0.0
        for await e in engine.events {
            t += 0.008
            if let r = session.handle(e, at: t) { saved = r; break }
        }
        #expect(saved?.outcome == .inserted)
        #expect(!(session.state.words.isEmpty))
    }
}
