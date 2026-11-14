import AppKit
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// Real `NSPasteboard`s, but private named ones: the general pasteboard is never read or written.
@MainActor
@Suite(.serialized) struct NamedPasteboardTests {
    func withBoard(_ body: (SystemPasteboard) throws -> Void) rethrows {
        let pb = SystemPasteboard.named()
        defer { pb.release() }
        precondition(pb.pasteboard.name != .general)
        try body(pb)
    }

    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.red, atX: 1, y: 1)
        return rep.representation(using: .png, properties: [:])!
    }

    /// Writes, snapshots, writes our transient text, restores, and checks everything came back.
    func roundTrip(_ pb: SystemPasteboard, _ write: (NSPasteboard) -> Void) throws -> PasteboardSnapshot {
        pb.pasteboard.clearContents()
        write(pb.pasteboard)
        let before = try pb.snapshot()
        let ours = pb.writeTransient("dictated") {}
        #expect(pb.pasteboard.string(forType: .string) == "dictated")
        #expect(pb.restore(before, ifChangeCount: ours))
        let after = try pb.snapshot()
        #expect(after.sameContent(as: before), "\(before.items.map { $0.entries.map { "\($0.type):\($0.data.count)" } }) -> \(after.items.map { $0.entries.map { "\($0.type):\($0.data.count)" } })")
        return before
    }

    @Test func namedBoardsAreReadable() {
        withBoard { pb in #expect(pb.access == .allowed) }
    }

    @Test func plainText() throws {
        try withBoard { pb in
            let s = try roundTrip(pb) { $0.setString("hello there", forType: .string) }
            #expect(s.items.count == 1)
            #expect(pb.pasteboard.string(forType: .string) == "hello there")
        }
    }

    @Test func richText() throws {
        try withBoard { pb in
            let rtf = try NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
                .data(from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            _ = try roundTrip(pb) {
                $0.declareTypes([.rtf, .string], owner: nil)
                $0.setData(rtf, forType: .rtf)
                $0.setString("bold", forType: .string)
            }
            #expect(pb.pasteboard.data(forType: .rtf) == rtf)
        }
    }

    @Test func image() throws {
        try withBoard { pb in
            let png = Self.png()
            _ = try roundTrip(pb) { $0.setData(png, forType: .png) }
            #expect(pb.pasteboard.data(forType: .png) == png)
        }
    }

    @Test func fileURL() throws {
        try withBoard { pb in
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
            _ = try roundTrip(pb) { $0.writeObjects([url as NSURL]) }
            let back = pb.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            #expect(back == [url])
        }
    }

    @Test func multipleItems() throws {
        try withBoard { pb in
            let s = try roundTrip(pb) { $0.writeObjects(["one" as NSString, "two" as NSString, URL(string: "https://example.com")! as NSURL]) }
            #expect(s.items.count == 3)
            let back = pb.pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }
            #expect(back?.prefix(2) == ["one", "two"])
        }
    }

    final class LazyProvider: NSObject, NSPasteboardItemDataProvider {
        var calls = 0
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            calls += 1
            item.setString("lazy text", forType: type)
        }
    }

    @Test func lazilyProvidedTypesAreCapturedAndRestoredAsData() throws {
        try withBoard { pb in
            let provider = LazyProvider()
            pb.pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            pb.pasteboard.writeObjects([item])
            let snap = try pb.snapshot()
            #expect(provider.calls == 1)
            #expect(snap.items.first?.data(NSPasteboard.PasteboardType.string.rawValue) == Data("lazy text".utf8))
            let ours = pb.writeTransient("x") {}
            #expect(pb.restore(snap, ifChangeCount: ours))
            #expect(pb.pasteboard.string(forType: .string) == "lazy text")
        }
    }

    @Test func transientWriteCarriesTheMarkersAndReportsTheRead() throws {
        try withBoard { pb in
            var reads = 0
            _ = pb.writeTransient("dictated") { reads += 1 }
            let types = Set(pb.pasteboard.types?.map(\.rawValue) ?? [])
            for marker in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.source"] {
                #expect(types.contains(marker), "missing \(marker)")
            }
            #expect(reads == 0)  // listing types is not a read
            #expect(pb.pasteboard.string(forType: .string) == "dictated")
            #expect(reads == 1)
        }
    }

    @Test func restoreRefusesAfterAnExternalWrite() throws {
        try withBoard { pb in
            pb.pasteboard.clearContents()
            pb.pasteboard.setString("user", forType: .string)
            let snap = try pb.snapshot()
            let ours = pb.writeTransient("dictated") {}
            pb.pasteboard.clearContents()
            pb.pasteboard.setString("someone else", forType: .string)
            #expect(!pb.restore(snap, ifChangeCount: ours))
            #expect(pb.pasteboard.string(forType: .string) == "someone else")
        }
    }

    @Test func emptyClipboardRestoresToEmpty() throws {
        try withBoard { pb in
            pb.pasteboard.clearContents()
            let snap = try pb.snapshot()
            #expect(snap.isEmpty)
            let ours = pb.writeTransient("dictated") {}
            #expect(pb.restore(snap, ifChangeCount: ours))
            #expect(pb.pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }

    @Test func inserterEndToEndOnANamedBoard() async throws {
        let pb = SystemPasteboard.named()
        defer { pb.release() }
        pb.pasteboard.clearContents()
        pb.pasteboard.setString("user clip", forType: .string)
        let before = try pb.snapshot()
        let keys = RecordingKeyPoster()
        var got: String?
        keys.onPaste = { _ in got = pb.pasteboard.string(forType: .string) }  // the "target" reads
        let field = FocusInfo(kind: .editableText, engine: .web, pid: 1, caret: .init(before: "", after: ""))
        let probe = ScriptedFocusProbe([field])
        var config = InsertionMachine.Config()
        config.quietAfterRead = 0.02
        config.minHoldAfterKey = 0.03
        let inserter = Inserter(parts: .init(
            pasteboard: pb, keys: keys, focus: probe, watcher: PollingFieldWatcher(probe: probe),
            accessibility: RecordingAccessibilityInserter(), environment: { .init(clipboard: pb.access, canPostKeys: true) }), config: config)
        let result = await inserter.insert("hello")
        #expect(result.outcome == .pasted)
        #expect(got == "hello ")
        let s = await result.settled.value
        #expect(s.readConfirmed)
        #expect(s.clipboard == .restored)
        #expect(try pb.snapshot().sameContent(as: before))
    }
}
