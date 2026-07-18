import SwiftUI

enum AdaptiveDrawer: Equatable {
    case leading
    case trailing
}

/// Window-scoped presentation state for the navigation sidebar and session
/// inspector. Docking is derived from window width; the drawer is transient,
/// so responsive changes never overwrite the user's saved visibility choices.
@MainActor
@Observable
final class AdaptivePanelLayout {
    private static let inspectorCollapseWidth: CGFloat = 960
    private static let inspectorRestoreWidth: CGFloat = 1_000
    private static let sidebarCollapseWidth: CGFloat = 720
    private static let sidebarRestoreWidth: CGFloat = 760

    private(set) var windowWidth: CGFloat = 1_280
    private(set) var docksSidebar = true
    private(set) var docksInspector = true
    private(set) var activeDrawer: AdaptiveDrawer?

    /// The sidebar column's TARGET trailing edge in window coordinates (its
    /// width when visible, 0 when hidden). Mutated inside `withAnimation`,
    /// and every dependent — the column's own frame width, the chrome
    /// cluster's offset, the detail header's reserve — derives from it via
    /// ANIMATABLE modifiers, so SwiftUI interpolates them per frame in one
    /// transaction and they move in true lockstep (the native
    /// tracking-separator model). Measured geometry can't do this:
    /// onGeometryChange doesn't stream during implicit animations (layout
    /// models jump to end values; only rendering interpolates).
    var sidebarEdge: CGFloat = 0

    func updateWindowWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0, abs(width - windowWidth) > 0.5 else { return }
        windowWidth = width

        if docksInspector, width < Self.inspectorCollapseWidth {
            docksInspector = false
        } else if !docksInspector, width > Self.inspectorRestoreWidth {
            docksInspector = true
            if activeDrawer == .trailing { activeDrawer = nil }
        }

        if docksSidebar, width < Self.sidebarCollapseWidth {
            docksSidebar = false
        } else if !docksSidebar, width > Self.sidebarRestoreWidth {
            docksSidebar = true
            if activeDrawer == .leading { activeDrawer = nil }
        }
    }

    func toggleDrawer(_ drawer: AdaptiveDrawer) {
        activeDrawer = activeDrawer == drawer ? nil : drawer
    }

    func dismissDrawer(_ drawer: AdaptiveDrawer? = nil) {
        guard drawer == nil || activeDrawer == drawer else { return }
        activeDrawer = nil
    }
}

/// A floating, edge-aligned panel above the primary content. Keeping this as
/// an overlay instead of another split-view column protects the chat's width
/// in compact windows.
struct AdaptiveDrawerLayer<DrawerContent: View>: View {
    @Environment(AdaptivePanelLayout.self) private var panelLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPresented: Bool
    let edge: Edge
    let width: CGFloat
    @ViewBuilder var drawerContent: () -> DrawerContent

    var body: some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            if isPresented {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { panelLayout.dismissDrawer() }
                    .transition(.opacity)

                drawerContent()
                    .frame(width: width)
                    .padding(8)
                    // Float BELOW the window's top bar (native transient
                    // panels leave the toolbar row clear).
                    .padding(.top, WindowChrome.headerHeight)
                    .transition(.move(edge: edge).combined(with: .opacity))
            }
        }
        .allowsHitTesting(isPresented)
        .onExitCommand { panelLayout.dismissDrawer() }
        .animation(Motion.quick(reduceMotion: reduceMotion), value: isPresented)
        // Anchor the layer to the true window top so the header clearance
        // above is measured from the real top edge, not the safe-area line.
        .ignoresSafeArea(edges: .top)
    }
}
