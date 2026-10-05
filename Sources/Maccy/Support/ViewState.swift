import SwiftUI

/// `@State` as a plain property wrapper. In the macOS 27 SDK, `@State` also
/// names a macro whose plugin ships with Xcode but not with the Command Line
/// Tools. The alias keeps the build working with the Command Line Tools only.
typealias ViewState = SwiftUI.State
