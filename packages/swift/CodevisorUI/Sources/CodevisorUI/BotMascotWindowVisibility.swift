import SwiftUI

#if os(macOS)
  import AppKit

  struct BotMascotWindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ProbeView {
      ProbeView { visible in
        guard isVisible != visible else { return }
        isVisible = visible
      }
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
      private let report: (Bool) -> Void
      private var observer: (any NSObjectProtocol)?

      init(report: @escaping (Bool) -> Void) {
        self.report = report
        super.init(frame: .zero)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe(window)
        reportVisibility()
      }

      private func observe(_ window: NSWindow?) {
        observer.map(NotificationCenter.default.removeObserver)
        observer = window.map {
          NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main
          ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportVisibility() }
          }
        }
      }

      private func reportVisibility() {
        guard let window else { return }

        report(window.occlusionState.contains(.visible))
      }
    }
  }
#else
  struct BotMascotWindowVisibility: View {
    @Binding var isVisible: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
      Color.clear
        .onChange(of: scenePhase, initial: true) { isVisible = scenePhase == .active }
    }
  }
#endif
