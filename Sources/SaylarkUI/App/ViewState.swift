import SwiftUI

/// `@State` is a macro in the macOS 27 SDK and the Command Line Tools ship without the SwiftUI macro
/// plugin, so views use the property wrapper through this alias instead.
typealias ViewState<T> = SwiftUI.State<T>
