import SwiftUI

/// SwiftUI's `State` property wrapper under a name that can't collide with
/// the `State` macro. Use `@ViewState` wherever you'd write `@State`.
///
/// The macOS 27 SDK declares a `macro State()` alongside the old property
/// wrapper, and the compiler resolves `@State` to the macro. The macro's
/// implementation (the `SwiftUIMacros` compiler plugin) ships only with full
/// Xcode, not with the Command Line Tools. On a CLT-only machine every
/// `@State` therefore fails to expand, and each write to it reports
/// "cannot assign to property: 'self' is immutable". Since the in-app updater
/// builds from source on the user's machine, that broke updates for anyone
/// without Xcode. Neither `@SwiftUI.State` nor a `typealias State` gets around
/// the macro, but an alias with a different name does. `build.sh` rejects a
/// bare `@State` so the problem can't come back.
typealias ViewState<Value> = SwiftUI.State<Value>
