import Testing
@testable import SaylarkCore

@Test func version() { #expect(!Saylark.version.isEmpty) }
