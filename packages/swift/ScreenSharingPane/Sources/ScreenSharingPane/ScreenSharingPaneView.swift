#if os(iOS)
  import SwiftUI
  import UIKit

  public struct ScreenSharingPaneView: View {
    let model: ScreenSharingPaneModel
    @State private var showsHint = false
    @AppStorage("screenSharing.touchHintShown") private var hintShown = false

    public init(model: ScreenSharingPaneModel) { self.model = model }

    public var body: some View {
      ZStack {
        Color(uiColor: .secondarySystemBackground).ignoresSafeArea()
        if model.receiver != nil {
          ScreenSharingCanvas(model: model)
            .ignoresSafeArea(.container)
            .opacity(model.phase == .viewing ? 1 : 0)
        }
        status
      }
      .overlay(alignment: .top) { controlNotice.padding(.top, 8) }
      .overlay(alignment: .bottom) {
        if showsHint { hint.padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity)) }
      }
      .animation(.snappy, value: model.control?.notice)
      .animation(.snappy, value: showsHint)
      .onAppear { model.appeared() }
      .onDisappear { model.disappeared() }
      .task(id: model.phase == .viewing) {
        guard model.phase == .viewing, !hintShown else { return }
        hintShown = true
        showsHint = true
        try? await Task.sleep(for: .seconds(5))
        showsHint = false
      }
      .task(id: model.control?.notice) {
        guard model.control?.notice != nil else { return }
        try? await Task.sleep(for: .seconds(4))
        model.control?.dismissNotice()
      }
    }

    @ViewBuilder private var status: some View {
      switch model.phase {
      case .loading, .connecting:
        ProgressView("Connecting to Mac…")
      case .reconnecting:
        ProgressView("Reconnecting…")
      case .viewing:
        EmptyView()
      case .failed(let message):
        ContentUnavailableView {
          Label("Can't Show This Mac", systemImage: "display.trianglebadge.exclamationmark")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") { model.retry() }
            .buttonStyle(.borderedProminent)
        }
      }
    }

    @ViewBuilder private var controlNotice: some View {
      if let notice = model.control?.notice, model.phase == .viewing {
        Label(notice, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .glassEffect(.regular, in: .capsule)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }

    private var hint: some View {
      VStack(alignment: .leading, spacing: 6) {
        Label("Tap to click", systemImage: "hand.tap")
        Label("Drag to move windows and files", systemImage: "hand.point.up.left")
        Label("Tap with two fingers to right-click", systemImage: "hand.tap")
        Label("Two fingers to scroll, pinch to zoom", systemImage: "hand.draw")
      }
      .font(.footnote)
      .padding(14)
      .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
  }

  public struct ScreenSharingPaneToolbar: ToolbarContent {
    let model: ScreenSharingPaneModel

    public init(model: ScreenSharingPaneModel) { self.model = model }

    public var body: some ToolbarContent {
      ToolbarItem(id: "screen-sharing.actions", placement: .topBarTrailing) {
        Menu {
          if model.displays.count > 1 {
            Picker(
              "Display",
              selection: Binding(
                get: { model.displayId ?? "" },
                set: { model.select(displayId: $0) })
            ) {
              ForEach(model.displays, id: \.id) { display in
                Text(display.name).tag(display.id)
              }
            }
          }
          Button("Paste from iPhone", systemImage: "doc.on.clipboard") {
            model.paste(UIPasteboard.general.string ?? "")
          }
          .disabled(model.phase != .viewing)
          if model.control?.state == .controlling {
            Button("Stop Controlling", systemImage: "hand.raised.slash") { model.control?.release() }
          }
          Button("Reconnect", systemImage: "arrow.clockwise") { model.retry() }
        } label: {
          Label("More", systemImage: "ellipsis")
        }
      }
      if model.phase == .viewing {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(id: "screen-sharing.keyboard", placement: .bottomBar) {
          Button {
            model.keyboardShown.toggle()
          } label: {
            Label(
              model.keyboardShown ? "Hide Keyboard" : "Show Keyboard",
              systemImage: model.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
          }
        }
      }
    }
  }
#endif
