//  App-owned window chrome: the header rows that replace the native
//  titlebar/toolbar (the main window uses `.hiddenTitleBar` — only the
//  traffic lights remain system-drawn).
//
//  Why the app owns this: the pane tab strip is a drag-driven custom control,
//  and AppKit's titlebar/toolbar machinery claims drags over toolbar-hosted
//  SwiftUI content through several independent mechanisms (toolbar blank-
//  space dragging, titlebar move regions) that don't consult SwiftUI
//  gestures. Owning the top bar as ordinary window content — the Zed/Chrome
//  model — removes the entire conflict class: interactive chrome behaves
//  like any other view, and window dragging is granted explicitly through
//  `WindowDragGap` regions in the blank space.

import SwiftUI

enum WindowChrome {
    /// Header row height, matching the old toolbar band.
    static let headerHeight: CGFloat = 52
    /// Leading clearance for the system traffic lights overlaying the window.
    static let trafficLightInset: CGFloat = 78
    /// The blank margins above/below a header row's controls; draggable
    /// window handle, like any native titlebar blank space.
    static let headerEdgeDragHeight: CGFloat = 8
}

extension View {
    /// Makes a header row's blank vertical margins drag the window. Full-
    /// width strips along the top and bottom edges, outside every control's
    /// hit area — a single full-row drag region would steal drags from the
    /// interactive content above it (WindowDragGesture regions claim drags
    /// geometrically, regardless of z-order).
    func headerEdgeDragHandles() -> some View {
        overlay(alignment: .top) {
            WindowDragGap()
                .frame(height: WindowChrome.headerEdgeDragHeight)
        }
        .overlay(alignment: .bottom) {
            WindowDragGap()
                .frame(height: WindowChrome.headerEdgeDragHeight)
        }
    }
}

/// Re-centers the system traffic lights on the app's 52pt header midline.
/// AppKit positions them for its own titlebar and offers no supported way to
/// re-center them (a titlebar-height accessory grows the bar but the buttons
/// stay top-anchored — tested), so manual placement it is: the pattern Zed
/// and Electron ship. Crucially every correction here is SYNCHRONOUS with
/// the event that moved the buttons — correcting on the next runloop lets
/// one wrong frame render first, which reads as flicker.
struct TrafficLightAligner: NSViewRepresentable {
    final class AlignerView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var frameObservations: [NSKeyValueObservation] = []
        private weak var observedCloseButton: NSView?
        private var isAligning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            frameObservations = []
            observedCloseButton = nil
            guard let window else { return }
            align()
            // didUpdate is the catch-all: it fires after every window update
            // pass (including layout animations settling), and the target
            // check in align() makes redundant firings free. The others give
            // immediate correction on their specific transitions.
            let names: [Notification.Name] = [
                NSWindow.didUpdateNotification,
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.align()
                }
            }
        }

        override func layout() {
            super.layout()
            align()
        }

        private static let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton, .miniaturizeButton, .zoomButton,
        ]

        private func align() {
            // Re-entrancy guard: our own setFrameOrigin re-fires the frame
            // KVO below synchronously.
            guard !isAligning, let window else { return }
            isAligning = true
            defer { isAligning = false }

            // AppKit RECREATES the buttons (and their titlebar views) on some
            // relayouts — sidebar collapse among them — which silently orphans
            // frame observations. Re-hook whenever the instances change.
            if let close = window.standardWindowButton(.closeButton),
               close !== observedCloseButton {
                rebuildFrameObservations(window: window)
            }
            for type in Self.buttonTypes {
                guard let button = window.standardWindowButton(type),
                      let container = button.superview else { continue }
                // Center the button on the header band's midline, measured
                // from the window's top edge (window base coords are
                // bottom-up; the container doesn't clip, so the button may
                // render below its nominal titlebar).
                let windowTop = container.convert(
                    NSPoint(x: 0, y: window.frame.height), from: nil
                ).y
                let targetY = windowTop - WindowChrome.headerHeight / 2 - button.frame.height / 2
                guard abs(button.frame.origin.y - targetY) > 0.5 else { continue }
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
            }
        }

        /// Watches the current button instances plus their titlebar ancestor
        /// views (AppKit often repositions the containers, not the buttons).
        /// Corrections run synchronously inside the KVO callback — guarded
        /// against re-entrancy — so the wrong position never reaches a
        /// rendered frame.
        private func rebuildFrameObservations(window: NSWindow) {
            frameObservations = []
            var observedViews: [NSView] = []
            for type in Self.buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                observedViews.append(button)
            }
            observedCloseButton = observedViews.first
            if let titlebar = observedViews.first?.superview {
                observedViews.append(titlebar)
                if let container = titlebar.superview {
                    observedViews.append(container)
                }
            }
            for view in observedViews {
                frameObservations.append(
                    view.observe(\.frame) { [weak self] _, _ in
                        self?.align()
                    }
                )
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { AlignerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Blank header space that drags the window (native titlebar behavior,
/// granted explicitly). Give it a frame or let it flex between controls.
struct WindowDragGap: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents()
            .accessibilityHidden(true)
    }
}

/// A circular Liquid Glass header button — the same treatment the toolbar
/// gave its items before the app took ownership of the top bar. Built from a
/// plain button + interactive glass (not `.buttonStyle(.glass)`) so menus
/// styled with `headerGlassCircle` render identically.
struct HeaderIconButton: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                // Regular weight: native toolbar symbols render unweighted.
                .font(.system(size: WindowChrome.headerButtonGlyphSize, weight: .regular))
                // Same ink as the machine picker's glyph.
                .foregroundStyle(theme.textPrimary)
                .frame(width: WindowChrome.headerButtonDiameter, height: WindowChrome.headerButtonDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .headerGlassCircle()
        .tooltip(help)
        .accessibilityLabel(help)
    }
}

extension WindowChrome {
    static let headerButtonDiameter: CGFloat = 36
    static let headerButtonGlyphSize: CGFloat = 18
}

extension View {
    /// The shared circular glass surface for header controls (buttons and
    /// menu labels alike).
    func headerGlassCircle() -> some View {
        glassEffect(.regular.interactive(), in: Circle())
    }
}

/// The top bar's page title — ONE style shared by every screen (native
/// `_NSToolbarTitleField`: SF Semibold 15, label color). Call sites align
/// its leading edge to `WindowChrome.pageTitleIndent` from their column's
/// leading edge so the title sits at the same x on every page.
struct HeaderPageTitle: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(theme.textPrimary)
    }
}

extension WindowChrome {
    /// The page title's indent from the detail column's leading edge.
    static let pageTitleIndent: CGFloat = 30
}

/// The native sidebar's behind-window vibrancy (NSVisualEffectView with the
/// `.sidebar` material) — SwiftUI's `Material` styles only blur in-window,
/// so the app-owned sidebar column uses the real thing for the system theme.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension WindowChrome {
    /// The chrome cluster's width: sidebar toggle + machine picker + spacing.
    static var clusterPairWidth: CGFloat { 2 * headerButtonDiameter + 8 }
    /// Where the cluster's LEADING edge docks (in window coordinates) once
    /// the sidebar is gone: all the way left, beside the traffic lights.
    static var clusterCollapsedSlotX: CGFloat { 10 + trafficLightInset + 8 }
    /// The cluster's trailing end when docked — the x the detail header's
    /// content must stay clear of.
    static var clusterCollapsedEnd: CGFloat { clusterCollapsedSlotX + clusterPairWidth }
    /// The cluster's inset from the sidebar's trailing edge while expanded.
    static let toggleDividerMargin: CGFloat = 10
}

/// The window's chrome control cluster — the app-owned equivalent of the
/// native toolbar's leading section. Overlaid at the window level ABOVE both
/// split columns (like NSToolbarView, which hosts every toolbar item in the
/// titlebar layer, never inside the sliding columns), so nothing here ever
/// re-mounts when the sidebar collapses. The machine picker + toggle move as
/// ONE unit tracking the sidebar's live trailing edge (the native
/// tracking-separator model) — riding the divider left during a collapse
/// until they dock beside the traffic lights, picker first.
struct SidebarToggleControl: View {
    @Environment(AdaptivePanelLayout.self) private var panelLayout
    @AppStorage("sidebar.collapsed") private var sidebarCollapsed = false

    var body: some View {
        HStack(spacing: 8) {
            MachinePickerToolbarMenu()
                .menuStyle(.button)
                .buttonStyle(.plain)
                // Match HeaderIconButton's glyph size.
                .font(.system(size: WindowChrome.headerButtonGlyphSize, weight: .regular))
                .frame(
                    width: WindowChrome.headerButtonDiameter,
                    height: WindowChrome.headerButtonDiameter
                )
                .contentShape(Circle())
                .headerGlassCircle()
            HeaderIconButton(systemImage: "sidebar.leading", help: "Toggle Sidebar") {
                // One transaction for both directions: the split view only
                // animates an EXPAND when the visibility change carries an
                // animation (collapse animates on its own — symmetric motion
                // is the native behavior, NSSplitViewController.toggleSidebar).
                withAnimation(.snappy(duration: 0.25)) {
                    if panelLayout.docksSidebar {
                        sidebarCollapsed.toggle()
                    } else {
                        panelLayout.toggleDrawer(.leading)
                    }
                }
            }
        }
        // Animatable divider-rider: as the sidebar edge animates, SwiftUI
        // interpolates this modifier per frame and the clamp runs on the
        // INTERPOLATED value — the cluster rides the divider as if part of
        // the sidebar, then docks; on expand it waits until the arriving
        // divider grabs it.
        .modifier(DividerRiderOffset(edge: panelLayout.sidebarEdge))
        .frame(height: WindowChrome.headerHeight, alignment: .leading)
    }
}

/// Offsets content to ride the (animating) sidebar trailing edge, clamped at
/// the docked slot beside the traffic lights. `Animatable` so the clamp is
/// evaluated against every interpolated frame of the edge animation — the
/// piecewise "glued to the divider, then stops" motion, not a straight lerp
/// between endpoints.
private struct DividerRiderOffset: ViewModifier, Animatable {
    var edge: CGFloat

    var animatableData: CGFloat {
        get { edge }
        set { edge = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: max(
            WindowChrome.clusterCollapsedSlotX,
            edge - WindowChrome.toggleDividerMargin - WindowChrome.clusterPairWidth
        ))
    }
}

/// Leading padding keeping detail-header content clear of the chrome cluster.
/// The detail column's leading edge IS the sidebar edge (spacing-0 split), so
/// the reserve is a pure function of the animating edge — evaluated per
/// interpolated frame, the content stays glued to the divider and stops
/// exactly where the docked cluster's trailing end stops.
private struct ChromeReservePadding: ViewModifier, Animatable {
    var edge: CGFloat

    var animatableData: CGFloat {
        get { edge }
        set { edge = newValue }
    }

    func body(content: Content) -> some View {
        let clusterEnd = max(
            WindowChrome.clusterCollapsedEnd,
            edge - WindowChrome.toggleDividerMargin
        )
        content.padding(.leading, max(0, clusterEnd + 8 - (edge + 10)))
    }
}

/// The sidebar column's header: pure background + window-drag surface. The
/// visible controls (`SidebarToggleControl`) are overlaid at the window
/// level so they survive the column collapsing; their footprints stay clear
/// of drag regions (drag regions claim drags geometrically, even under
/// overlaid buttons).
struct SidebarHeaderBar: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            WindowDragGap()
                .frame(width: WindowChrome.trafficLightInset)
            WindowDragGap()
            // The divider-tracking cluster (toggle + machine picker) sits at
            // the trailing edge while expanded; clear of drag regions.
            Color.clear
                .frame(width: WindowChrome.clusterPairWidth)
        }
        .padding(.horizontal, 10)
        .frame(height: WindowChrome.headerHeight)
        .frame(maxWidth: .infinity)
        .headerEdgeDragHandles()
    }
}

/// A detail-column header: hosts the screen's own header content (tab strip,
/// title, actions), keeping its leading edge clear of the window-level chrome
/// cluster via the edge-animatable reserve (ChromeReservePadding), so during
/// a sidebar collapse the content slides exactly in step with the moving
/// divider — no overshoot, no double animation.
struct DetailHeaderBar<Content: View>: View {
    @Environment(AdaptivePanelLayout.self) private var panelLayout
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        // Keeps the content clear of the chrome cluster, animating in
        // lockstep with the sidebar edge (see ChromeReservePadding).
        .modifier(ChromeReservePadding(edge: panelLayout.sidebarEdge))
        .padding(.horizontal, 10)
        .frame(height: WindowChrome.headerHeight)
        .frame(maxWidth: .infinity)
        // The toolbar-band surface the native bar used to paint: system
        // themes keep the bar material, custom palettes their own surface.
        .background(
            theme.isSystem
                ? AnyShapeStyle(.bar)
                : AnyShapeStyle(theme.windowBackground)
        )
        .headerEdgeDragHandles()
        // The band/content boundary line.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
        }
    }
}
