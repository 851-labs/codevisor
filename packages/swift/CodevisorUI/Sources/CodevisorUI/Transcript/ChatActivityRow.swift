import SwiftUI

public struct ChatActivityRow: View {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        HStack {
            ShimmeringText(text: message)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
