import SwiftUI

extension View {
    /// Apply a transform to `self` inline. Handy for attaching platform-specific modifiers behind an
    /// `#if` without breaking the modifier chain or the `some View` opaque return type.
    @ViewBuilder func modify<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> Content {
        transform(self)
    }
}
