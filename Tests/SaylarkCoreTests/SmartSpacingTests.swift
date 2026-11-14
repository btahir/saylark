import Testing
@testable import SaylarkCore

@Suite struct SmartSpacingTests {
    func s(_ text: String, before: String?, after: String? = nil, trailing: Bool = true) -> String {
        SmartSpacing.apply(text, caret: .init(before: before, after: after), trailingSpace: trailing)
    }

    @Test func unknownContextIsWisprStyle() {
        #expect(s("hello world", before: nil) == "hello world ")
        #expect(s("  hello  ", before: nil) == "hello ")
    }

    @Test func startOfFieldHasNoLeadingSpace() {
        #expect(s("Hello", before: "") == "Hello ")
    }

    @Test func continuingAfterAWordAddsOneSpace() {
        #expect(s("and then", before: "rd") == " and then ")
        #expect(s("and then", before: "d.") == " and then ")
        #expect(s("and then", before: "d,") == " and then ")
    }

    @Test func neverDoublesASpace() {
        #expect(s("next", before: "d ") == "next ")
        #expect(s(" next", before: "d ") == "next ")
        #expect(s("next", before: "\t") == "next ")
    }

    @Test func noSpaceAfterNewlineOrOpeners() {
        #expect(s("Item", before: "\n") == "Item ")
        for opener in ["(", "[", "{", "“", "/", "@", "#"] {
            #expect(s("word", before: "x" + opener) == "word ", "after \(opener)")
        }
    }

    @Test func straightQuotesAndHyphens() {
        #expect(s("quoted", before: " \"") == "quoted ")  // opening quote
        #expect(s("quoted", before: "\"") == "quoted ")  // opening quote at field start
        #expect(s("next", before: "i\"") == " next ")  // closing quote
        #expect(s("next", before: "s'") == " next ")  // apostrophe after a word
        #expect(s("word", before: "e-") == "word ")  // hyphen inside a word
        #expect(s("word", before: " -") == " word ")  // a dash
    }

    @Test func leftAttachingPunctuationTakesNoLeadingSpace() {
        #expect(s(", right", before: "ok") == ", right ")
        #expect(s(".", before: "ok") == ". ")
        #expect(s("\nnext", before: "ok") == "\nnext ")
    }

    @Test func trailingSpaceRules() {
        #expect(s("line\n", before: nil) == "line\n")
        #expect(s("word", before: "", after: " ") == "word")
        #expect(s("word", before: "", after: ".") == "word")
        #expect(s("word", before: "", after: "x") == "word ")
        #expect(s("word", before: "", after: "") == "word ")
        #expect(s("word", before: nil, trailing: false) == "word")
    }

    @Test func insideAQuotePair() {
        #expect(s("hi", before: "\"", after: "\"") == "hi")
    }

    @Test func emptyStaysEmpty() {
        #expect(s("   ", before: "x") == "")
        #expect(s("", before: nil) == "")
    }

    @Test func consecutiveDictationsJoinWithOneSpace() {
        // The first dictation ended with Wispr's trailing space; the second sees it before the caret.
        let first = s("One.", before: "")
        let second = s("Two.", before: String(first.suffix(2)))
        #expect(first + second == "One. Two. ")
    }
}

@Suite struct FocusClassifierTests {
    func kind(_ role: String?, subrole: String? = nil, editable: Bool? = nil, value: Bool = false, sel: Bool = false,
              engine: FocusInfo.Engine = .native, focused: Bool = true) -> FocusInfo.Kind {
        FocusClassifier.kind(hasFocusedElement: focused, role: role, subrole: subrole, editable: editable,
                             valueSettable: value, selectedTextSettable: sel, engine: engine)
    }

    @Test func textFields() {
        #expect(kind("AXTextField", value: true) == .editableText)
        #expect(kind("AXTextArea", sel: true) == .editableText)
        #expect(kind("AXComboBox", value: true) == .editableText)
    }

    @Test func secureFieldWins() {
        #expect(kind("AXTextField", subrole: "AXSecureTextField", value: true) == .secureText)
    }

    @Test func readOnlyTextAreaIsUnknownNotCard() {
        // Terminal's text area is not settable but takes a paste.
        #expect(kind("AXTextArea") == .unknown)
    }

    @Test func webEditable() {
        #expect(kind("AXGroup", editable: true, engine: .web) == .editableText)
        #expect(kind("AXWebArea", engine: .web) == .unknown)
    }

    @Test func clearNonTextOnlyInNativeApps() {
        #expect(kind("AXButton") == .notText)
        #expect(kind("AXList") == .notText)
        #expect(kind("AXButton", engine: .web) == .unknown)
        #expect(kind("AXButton", engine: .unknown) == .unknown)
    }

    @Test func noFocusedElement() {
        #expect(kind(nil, focused: false) == .notText)
        #expect(kind(nil, engine: .web, focused: false) == .unknown)
    }

    @Test func ambiguousRolesAreUnknown() {
        #expect(kind("AXGroup", engine: .web) == .unknown)
        #expect(kind("AXScrollArea", engine: .unknown) == .unknown)
        #expect(kind(nil) == .unknown)
        #expect(kind("AXSomethingCustom") == .unknown)
    }

    /// The Finder desktop and other native containers hold focus only when no text field does.
    @Test func nativeContainersAreNotText() {
        #expect(kind("AXGroup") == .notText)
        #expect(kind("AXScrollArea") == .notText)
        #expect(kind("AXWindow") == .notText)
        // A container that takes text is still text.
        #expect(kind("AXGroup", editable: true) == .editableText)
        #expect(kind("AXScrollArea", sel: true) == .editableText)
    }

    /// Finder makes a clipping file from a blind paste, so an unclear focus there is not text.
    @Test func finderNeverGetsABlindPaste() {
        let finder = FocusInfo(kind: .unknown, bundleID: "com.apple.finder", note: "accessibility off")
        #expect(FocusClassifier.refine(finder).kind == .notText)
        let field = FocusInfo(kind: .editableText, bundleID: "com.apple.finder")
        #expect(FocusClassifier.refine(field).kind == .editableText)
        let other = FocusInfo(kind: .unknown, bundleID: "com.anthropic.claudefordesktop")
        #expect(FocusClassifier.refine(other).kind == .unknown)
    }

    @Test func accessibilityInsertOnlyInNativeSettableFields() {
        var f = FocusInfo(kind: .editableText, engine: .native, canSetSelectedText: true)
        #expect(f.allowsAccessibilityInsert)
        f.engine = .web
        #expect(!f.allowsAccessibilityInsert)
        f.engine = .native
        f.canSetSelectedText = false
        #expect(!f.allowsAccessibilityInsert)
    }
}
