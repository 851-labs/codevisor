import SwiftUI
import UIKit

#if DEBUG || NAVIGATION_DIAGNOSTICS
import os
#endif

/// The SwiftUI-side state expected to produce the workspace's navigation
/// chrome. Diagnostics-enabled builds pair it with UIKit snapshots so an intermittent
/// missing-toolbar report can distinguish incorrect app state from a stuck
/// `UINavigationController` transition.
struct IOSNavigationDiagnosticState: Equatable {
    let screen: String
    let identifier: String
    let showsGrid: Bool
    let isNewChatPresentation: Bool
    let hasStarted: Bool
    let isDraft: Bool
    let blocksServerContent: Bool
    let expectsNativeBack: Bool
    let expectsLeadingButton: Bool
    let expectsTrailingButton: Bool
    let contentPhase: String

    var summary: String {
        [
            "screen=\(screen)",
            "id=\(identifier)",
            "grid=\(showsGrid)",
            "newChat=\(isNewChatPresentation)",
            "started=\(hasStarted)",
            "draft=\(isDraft)",
            "blocked=\(blocksServerContent)",
            "expectBack=\(expectsNativeBack)",
            "expectLeading=\(expectsLeadingButton)",
            "expectTrailing=\(expectsTrailingButton)",
            "content=\(contentPhase)",
        ].joined(separator: " ")
    }
}

@MainActor
enum IOSNavigationDiagnostics {
#if DEBUG || NAVIGATION_DIAGNOSTICS
    private static let logger = Logger(
        subsystem: "com.851labs.codevisor",
        category: "ios-navigation"
    )
    private static var sequence: UInt64 = 0
#endif

    static func record(_ event: String, _ details: String = "") {
#if DEBUG || NAVIGATION_DIAGNOSTICS
        sequence &+= 1
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "NAVDBG #\(sequence) \(event)\(suffix)"
        logger.notice("\(message, privacy: .public)")
#endif
    }
}

extension View {
    @ViewBuilder
    func iosNavigationDiagnostics(_ state: IOSNavigationDiagnosticState) -> some View {
#if DEBUG || NAVIGATION_DIAGNOSTICS
        modifier(IOSNavigationDiagnosticsModifier(state: state))
#else
        self
#endif
    }
}

#if DEBUG || NAVIGATION_DIAGNOSTICS
private struct IOSNavigationDiagnosticsModifier: ViewModifier {
    let state: IOSNavigationDiagnosticState

    func body(content: Content) -> some View {
        content
            .background {
                IOSNavigationControllerProbe(state: state)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear {
                IOSNavigationDiagnostics.record("workspace.appear", state.summary)
            }
            .onDisappear {
                IOSNavigationDiagnostics.record("workspace.disappear", state.summary)
            }
            .onChange(of: state) { oldValue, newValue in
                IOSNavigationDiagnostics.record(
                    "workspace.state",
                    "old={\(oldValue.summary)} new={\(newValue.summary)}"
                )
            }
    }
}

private struct IOSNavigationControllerProbe: UIViewControllerRepresentable {
    let state: IOSNavigationDiagnosticState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ProbeViewController {
        let controller = ProbeViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        context.coordinator.attach(controller)
        context.coordinator.update(state: state, probe: controller, reason: "make")
        return controller
    }

    func updateUIViewController(
        _ uiViewController: ProbeViewController,
        context: Context
    ) {
        context.coordinator.update(state: state, probe: uiViewController, reason: "update")
    }

    static func dismantleUIViewController(
        _ uiViewController: ProbeViewController,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
        IOSNavigationDiagnostics.record("probe.dismantle", coordinator.lastState?.summary ?? "")
    }

    @MainActor
    final class Coordinator {
        fileprivate var lastState: IOSNavigationDiagnosticState?
        private var generation: UInt64 = 0

        func attach(_ probe: ProbeViewController) {
            probe.onDidMove = { [weak self, weak probe] in
                guard let self, let probe, let state = self.lastState else { return }
                self.scheduleSnapshots(state: state, probe: probe, reason: "didMove")
            }
        }

        func update(
            state: IOSNavigationDiagnosticState,
            probe: ProbeViewController,
            reason: String
        ) {
            guard lastState != state else { return }
            lastState = state
            scheduleSnapshots(state: state, probe: probe, reason: reason)
        }

        func invalidate() {
            generation &+= 1
        }

        private func scheduleSnapshots(
            state: IOSNavigationDiagnosticState,
            probe: ProbeViewController,
            reason: String
        ) {
            generation &+= 1
            let requestedGeneration = generation
            IOSNavigationDiagnostics.record("probe.schedule", "reason=\(reason) \(state.summary)")

            for delay in [0, 100, 250, 500, 1_000, 2_000, 5_000] {
                Task { @MainActor [weak self, weak probe] in
                    if delay > 0 {
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    guard let self,
                          self.generation == requestedGeneration,
                          self.lastState == state,
                          let probe else { return }
                    self.snapshot(state: state, probe: probe, delay: delay)
                }
            }
        }

        private func snapshot(
            state: IOSNavigationDiagnosticState,
            probe: UIViewController,
            delay: Int
        ) {
            guard let navigationController = Self.navigationController(for: probe) else {
                IOSNavigationDiagnostics.record(
                    "uikit.snapshot",
                    "delayMs=\(delay) nav=missing window=\(probe.viewIfLoaded?.window != nil) \(state.summary)"
                )
                return
            }

            let navigationBar = navigationController.navigationBar
            let topController = navigationController.topViewController
            let topItem = navigationBar.topItem
            let popGesture = navigationController.interactivePopGestureRecognizer
            let transition = navigationController.transitionCoordinator
            let labels = Self.visibleAccessibilityLabels(in: navigationBar).joined(separator: ",")
            let topOwnsProbe = topController.map { Self.isAncestor($0, of: probe) } ?? false
            let topType = topController.map { String(describing: type(of: $0)) } ?? "nil"
            let transitionDescription: String
            if let transition {
                transitionDescription = [
                    "active",
                    "animated=\(transition.isAnimated)",
                    "interactive=\(transition.isInteractive)",
                    "initialInteractive=\(transition.initiallyInteractive)",
                ].joined(separator: ":")
            } else {
                transitionDescription = "none"
            }
            let barVisible = !navigationBar.isHidden
                && navigationBar.alpha > 0.01
                && navigationBar.window != nil
                && navigationBar.bounds.height > 0
            let rightCount = topItem?.rightBarButtonItems?.count ?? 0
            let leftCount = topItem?.leftBarButtonItems?.count ?? 0
            let hasExpectedLabel = !state.expectsTrailingButton
                || labels.contains("Show tabs")
                || labels.contains("New tab")
                || labels.contains("Cancel")
            let anomaly = !barVisible
                || !topOwnsProbe
                || !hasExpectedLabel
                || (state.expectsNativeBack
                    && navigationController.viewControllers.count > 1
                    && popGesture?.isEnabled != true)

            IOSNavigationDiagnostics.record(
                anomaly ? "uikit.snapshot.ANOMALY" : "uikit.snapshot",
                [
                    "delayMs=\(delay)",
                    "depth=\(navigationController.viewControllers.count)",
                    "top=\(topType)",
                    "topOwnsProbe=\(topOwnsProbe)",
                    "barVisible=\(barVisible)",
                    "barHidden=\(navigationController.isNavigationBarHidden)",
                    "barAlpha=\(String(format: "%.2f", navigationBar.alpha))",
                    "barHeight=\(String(format: "%.1f", navigationBar.bounds.height))",
                    "items=\(navigationBar.items?.count ?? 0)",
                    "left=\(leftCount)",
                    "right=\(rightCount)",
                    "hidesBack=\(topItem?.hidesBackButton ?? false)",
                    "labels=[\(labels)]",
                    "popEnabled=\(popGesture?.isEnabled.description ?? "nil")",
                    "popState=\(popGesture.map { String(describing: $0.state) } ?? "nil")",
                    "popDelegate=\(popGesture?.delegate.map { String(describing: type(of: $0)) } ?? "nil")",
                    "transition=\(transitionDescription)",
                    state.summary,
                ].joined(separator: " ")
            )
        }

        private static func navigationController(for probe: UIViewController) -> UINavigationController? {
            if let navigationController = probe.navigationController {
                return navigationController
            }
            guard let root = probe.viewIfLoaded?.window?.rootViewController
                ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })?
                    .keyWindow?.rootViewController
            else { return nil }
            return findNavigationController(in: root)
        }

        private static func findNavigationController(
            in controller: UIViewController
        ) -> UINavigationController? {
            if let navigationController = controller as? UINavigationController {
                return navigationController
            }
            if let presented = controller.presentedViewController,
               let navigationController = findNavigationController(in: presented) {
                return navigationController
            }
            for child in controller.children.reversed() {
                if let navigationController = findNavigationController(in: child) {
                    return navigationController
                }
            }
            return nil
        }

        private static func isAncestor(
            _ possibleAncestor: UIViewController,
            of controller: UIViewController
        ) -> Bool {
            var current: UIViewController? = controller
            while let candidate = current {
                if candidate === possibleAncestor { return true }
                current = candidate.parent
            }
            return false
        }

        private static func visibleAccessibilityLabels(in root: UIView) -> [String] {
            var labels: [String] = []
            var stack = [root]
            while let view = stack.popLast() {
                guard !view.isHidden, view.alpha > 0.01 else { continue }
                if let label = view.accessibilityLabel, !label.isEmpty {
                    labels.append(label)
                }
                stack.append(contentsOf: view.subviews)
            }
            return Array(Set(labels)).sorted()
        }
    }
}

@MainActor
private final class ProbeViewController: UIViewController {
    var onDidMove: (() -> Void)?

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        onDidMove?()
    }
}
#endif
