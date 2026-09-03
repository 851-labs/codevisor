#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    /// The container for one popup. Owns the keyboard from the moment it
    /// appears (arrows, ⌃N/⌃P, Return, Escape), tracks which items are
    /// reachable, and keeps `highlight` consistent with what the list shows.
    /// Size it from outside like any view (`.frame(width:)`).
    struct Root<ID: Hashable, Content: View>: View {
      let highlight: Highlight<ID>
      let isDisabled: Bool
      let onDismiss: () -> Void
      let content: Content

      @State private var host = Host()

      public init(
        highlight: Highlight<ID>,
        isDisabled: Bool = false,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
      ) {
        self.highlight = highlight
        self.isDisabled = isDisabled
        self.onDismiss = onDismiss
        self.content = content()
      }

      public var body: some View {
        VStack(spacing: 0) {
          content
        }
        .environment(highlight)
        .environment(host)
        .onPreferenceChange(TargetsKey.self) { targets in
          MainActor.assumeIsolated {
            host.targets = targets
            highlight.reconcile(with: navigableIDs(in: targets))
          }
        }
        .onChange(of: isDisabled, initial: true) { _, isDisabled in
          host.isDisabled = isDisabled
          // Nothing should look actionable while disabled; the highlight
          // comes back with the next pointer or key input once re-enabled.
          if isDisabled {
            highlight.reset()
          }
        }
        // Only keyboard moves scroll; scrolling under a hovering pointer
        // would move the item out from under it.
        .onChange(of: highlight.highlighted) { _, target in
          guard
            let target, highlight.source == .keyboard,
            host.targets.contains(Target(id: AnyHashable(target), kind: .item))
          else { return }
          host.scroll(to: AnyHashable(target))
        }
        .onAppear {
          host.send = handle
          // Start clean, then let `autoHighlight` seed the first item if the
          // targets already arrived (preferences can land before onAppear).
          highlight.reset()
          highlight.reconcile(with: navigableIDs(in: host.targets))
        }
        .onDisappear {
          highlight.reset()
        }
        .background {
          KeyMonitor(onCommand: handle)
            .frame(width: 0, height: 0)
        }
      }

      private func navigableIDs(in targets: [Target]) -> [ID] {
        targets.compactMap { target in
          guard target.kind != .groupLabel else { return nil }
          return target.id as? ID
        }
      }

      private func handle(_ command: KeyCommand) {
        // Disabled popups still dismiss on Escape but ignore navigation and
        // acceptance.
        if host.isDisabled, command != .dismiss { return }
        highlight.handle(
          command,
          targets: navigableIDs(in: host.targets),
          accept: { host.accept(AnyHashable($0)) },
          dismiss: onDismiss
        )
      }
    }
  }

  extension Autocomplete {
    /// A window-wide key monitor that turns arrow, Return, Escape, and the
    /// Emacs-style ⌃N/⌃P bindings into commands while the popup is presented.
    /// It keeps navigation working even if focus leaves the input.
    struct KeyMonitor: NSViewRepresentable {
      let onCommand: (KeyCommand) -> Void

      func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
      }

      func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView()
      }

      func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommand = onCommand
        context.coordinator.installMonitor()
      }

      static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
      }

      @MainActor
      final class Coordinator {
        var onCommand: (KeyCommand) -> Void
        private var monitor: Any?

        init(onCommand: @escaping (KeyCommand) -> Void) {
          self.onCommand = onCommand
        }

        func installMonitor() {
          guard monitor == nil else { return }
          monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let command = Self.command(for: event) else { return event }
            onCommand(command)
            return nil
          }
        }

        func removeMonitor() {
          guard let monitor else { return }
          NSEvent.removeMonitor(monitor)
          self.monitor = nil
        }

        static func command(for event: NSEvent) -> KeyCommand? {
          let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
          let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
          if shortcutModifiers == .control {
            switch event.keyCode {
            case 38: return .moveDown  // ⌃N
            case 40: return .moveUp  // ⌃P
            default: return nil
            }
          }
          guard shortcutModifiers.isEmpty else { return nil }
          switch event.keyCode {
          case 126: return .moveUp
          case 125: return .moveDown
          case 36, 76: return .accept
          case 53: return .dismiss
          default: return nil
          }
        }
      }
    }
  }
#endif
