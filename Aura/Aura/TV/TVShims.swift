import SwiftUI

extension View {
    /// The phone's loading shimmer lives in a view the TV app leaves out; a dimmed
    /// placeholder says the same thing.
    func shimmering() -> some View { opacity(0.6) }
}
