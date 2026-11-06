import SwiftUI

#if canImport(AppKit)
  public struct FilePaneToolbar: ToolbarContent {
    private let model: FilePaneModel

    public init(model: FilePaneModel) {
      self.model = model
    }

    public var body: some ToolbarContent {
      ToolbarItem(id: "file.title", placement: .navigation) {
        Text(model.title)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 260, alignment: .leading)
          .padding(.leading, 12)
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarSpacer(.flexible)
      ToolbarItemGroup(placement: .primaryAction) {
        FilePanePreviewToggle(model: model)
      }
    }
  }
#else
  public struct FilePaneToolbar: ToolbarContent {
    private let model: FilePaneModel
    private let onNewTab: () -> Void

    public init(model: FilePaneModel, onNewTab: @escaping () -> Void) {
      self.model = model
      self.onNewTab = onNewTab
    }

    public var body: some ToolbarContent {
      ToolbarItem(id: "file.title", placement: .principal) {
        if model.isBrowsing {
          Text(model.title).font(.headline)
        } else {
          FilePaneTitleButton(model: model)
        }
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarItemGroup(placement: .primaryAction) {
        FilePanePreviewToggle(model: model)
        if !model.isBrowsing {
          FilePaneActions(model: model, onNewTab: onNewTab)
        }
      }
    }
  }

  private struct FilePaneTitleButton: View {
    let model: FilePaneModel

    var body: some View {
      Button {
        model.openExplorer()
      } label: {
        HStack(spacing: 6) {
          Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 260)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(model.title), Open File")
      .help("Open File")
    }
  }

  private struct FilePaneActions: View {
    @Bindable var model: FilePaneModel
    let onNewTab: () -> Void

    var body: some View {
      Menu {
        Button("Open File", systemImage: "doc.text.magnifyingglass") { model.openExplorer() }
          .keyboardShortcut("o", modifiers: .command)
        if model.document.hasPreview {
          Button(
            model.editor.preview ? "Show Editor" : "Show Preview",
            systemImage: model.editor.preview ? "pencil" : "eye"
          ) {
            model.editor.preview.toggle()
          }
        }
        if model.document.snapshot?.content != nil {
          Divider()
          Button("Find…", systemImage: "magnifyingglass") {
            model.showsFind.toggle()
            model.editor.preview = false
          }
          .keyboardShortcut("f", modifiers: .command)
          Button("Go to Line…", systemImage: "number") { model.showsGoToLine = true }
            .keyboardShortcut("g", modifiers: .control)
        }
        Divider()
        Button("Reload from Machine", systemImage: "arrow.clockwise") { Task { await model.refreshDocument() } }
        Divider()
        Button("New Tab", systemImage: "plus.square.on.square") { onNewTab() }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuIndicator(.hidden)
      .accessibilityLabel("File Actions")
      .help("File Actions")
    }
  }
#endif
