import SwiftUI
import UIKit

extension HomeView {
    /// A bitmap of the key window, used as the frozen backdrop while a new
    /// chat promotes into its workspace. Split from `HomeView` so the view's
    /// body stays within the size ratchet.
    func currentHomeSnapshot() -> UIImage? {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: \.isKeyWindow),
            !window.bounds.isEmpty
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    @ViewBuilder func promotionHomeSnapshot(_ flow: NewChatFlow) -> some View {
        Group {
            if let snapshot = flow.homeSnapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .interpolation(.none)
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
    }
}
