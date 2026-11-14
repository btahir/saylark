/// What had keyboard focus at one moment, as read through accessibility. Plain data: the Engine's
/// `FocusProbe` fills it in, and `InsertionMachine` decides from it. No AppKit here.
public struct FocusInfo: Sendable, Equatable {
    /// How sure we are that typing would land in a text field.
    public enum Kind: Sendable, Equatable {
        /// A text field, text view, combo box or editable web element.
        case editableText
        /// A password field. We never paste into it.
        case secureText
        /// Focus is clearly not text: a button, list, table, menu, or no focused element at all in
        /// an app whose accessibility we trust. This is the only kind that shows the card up front.
        case notText
        /// Could not tell: accessibility is off or timed out, a custom view, a terminal, an
        /// Electron or web area. We paste and rely on the read receipt.
        case unknown
    }

    /// What drew the focused app's UI, which decides how far its accessibility answers can be
    /// trusted and whether accessibility insertion is safe.
    public enum Engine: Sendable, Equatable {
        /// AppKit, SwiftUI, Catalyst: accessibility is complete and setting selected text works.
        case native
        /// Electron or a Chromium browser: the tree may be off or partial, and setting selected
        /// text does not fire DOM input events, so paste only.
        case web
        case unknown
    }

    /// The character context around the caret, for smart spacing. Up to two characters before
    /// the selection start (`""` = start of the field) and one after the selection end
    /// (`""` = end of the field). `nil` = not known.
    public struct Caret: Sendable, Equatable {
        public var before: String?
        public var after: String?
        public init(before: String? = nil, after: String? = nil) {
            self.before = before
            self.after = after
        }
        public static let unknown = Caret()
    }

    public var kind: Kind
    public var engine: Engine
    public var pid: Int32?
    public var bundleID: String?
    public var role: String?
    public var subrole: String?
    /// Identity of the focused element (a hash of the accessibility element), to tell whether
    /// focus is still on the same field. `nil` when unknown.
    public var elementID: UInt?
    /// Selection in UTF-16 units, when the element reports it.
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var caret: Caret
    /// The element accepts `AXSelectedText` writes (accessibility insertion is possible).
    public var canSetSelectedText: Bool
    /// How long the probe took, in milliseconds.
    public var probeMs: Double
    /// Why the answer is `.unknown`, for logs ("accessibility off", "timed out", …).
    public var note: String?

    public init(
        kind: Kind, engine: Engine = .unknown, pid: Int32? = nil, bundleID: String? = nil,
        role: String? = nil, subrole: String? = nil, elementID: UInt? = nil,
        selectionLocation: Int? = nil, selectionLength: Int? = nil, caret: Caret = .unknown,
        canSetSelectedText: Bool = false, probeMs: Double = 0, note: String? = nil
    ) {
        self.kind = kind
        self.engine = engine
        self.pid = pid
        self.bundleID = bundleID
        self.role = role
        self.subrole = subrole
        self.elementID = elementID
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.caret = caret
        self.canSetSelectedText = canSetSelectedText
        self.probeMs = probeMs
        self.note = note
    }

    /// Nothing could be read (accessibility off, timeout).
    public static func unknown(pid: Int32? = nil, bundleID: String? = nil, note: String? = nil) -> FocusInfo {
        FocusInfo(kind: .unknown, pid: pid, bundleID: bundleID, note: note)
    }

    /// Accessibility insertion is allowed here: a native, editable, settable field. Never for
    /// Chromium/Electron, where the write "succeeds" without the page's own state updating.
    public var allowsAccessibilityInsert: Bool {
        kind == .editableText && engine == .native && canSetSelectedText
    }
}

/// Turns raw accessibility attributes into a `FocusInfo.Kind`. Pure, so the rules are tested.
///
/// The bias is deliberate: only roles that can never take typed text count as `.notText`.
/// Anything ambiguous (AXGroup, AXScrollArea, AXWebArea, a read-only AXTextArea such as a
/// terminal, a custom view) is `.unknown`, which means "paste and watch for the read receipt".
/// Showing the card in a field that would have accepted the paste is the worse failure.
public enum FocusClassifier {
    /// Roles that are text inputs.
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that never take typed text.
    public static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXColumn", "AXBrowser", "AXImage", "AXSlider",
        "AXScrollBar", "AXToolbar", "AXTabGroup", "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXMenuItem",
        "AXIncrementor", "AXColorWell", "AXLevelIndicator", "AXProgressIndicator", "AXDockItem",
        "AXSplitter", "AXHandle", "AXRuler", "AXStaticText",
    ]

    /// Layout containers. In a native app they only hold focus when nothing that takes text does
    /// (the Finder desktop, an icon view, an empty window), so there they count as `.notText`.
    public static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXWindow", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem",
        "AXApplication", "AXSheet", "AXDrawer", "AXGrid", "AXCell", "AXMatte",
    ]

    /// Apps where a paste outside a text field does something unwanted (Finder makes a clipping
    /// file on the desktop). Anything there that is not clearly a text field is `.notText`.
    public static let neverPasteBlind: Set<String> = ["com.apple.finder"]

    /// Applies the per-app rule to a probe result. A text field or password field is left alone.
    public static func refine(_ info: FocusInfo) -> FocusInfo {
        guard info.kind == .unknown, let id = info.bundleID, neverPasteBlind.contains(id) else { return info }
        var out = info
        out.kind = .notText
        return out
    }

    public static func kind(
        hasFocusedElement: Bool, role: String?, subrole: String?, editable: Bool?,
        valueSettable: Bool, selectedTextSettable: Bool, engine: FocusInfo.Engine
    ) -> FocusInfo.Kind {
        guard hasFocusedElement else {
            // No focused element in a native app: nowhere for text to go (Finder desktop, an
            // empty window). In Chromium this is also what "accessibility not built yet" looks like.
            return engine == .native ? .notText : .unknown
        }
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return .secureText }
        if editable == true { return .editableText }
        if let role, textRoles.contains(role) {
            return (valueSettable || selectedTextSettable) ? .editableText : .unknown
        }
        if selectedTextSettable { return .editableText }
        if let role, nonTextRoles.contains(role) {
            // Chromium can report a stale non-text role while its tree is half built.
            return engine == .native ? .notText : .unknown
        }
        if let role, containerRoles.contains(role), engine == .native { return .notText }
        return .unknown
    }
}
