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
        Button(action: model.openExplorer) { label("Open File", "doc.text.magnifyingglass") }
          .keyboardShortcut("o", modifiers: .command)
        if model.document.hasPreview {
          Button {
            model.editor.preview.toggle()
          } label: {
            label(previewToggleTitle, previewToggleIcon)
          }
        }
        if model.document.snapshot?.content != nil {
          Divider()
          Button {
            model.showsFind.toggle()
            model.editor.preview = false
          } label: {
            label("Find…", "magnifyingglass")
          }
          .keyboardShortcut("f", modifiers: .command)
          Button {
            model.showsGoToLine = true
          } label: {
            label("Go to Line…", "number")
          }
          .keyboardShortcut("g", modifiers: .control)
        }
        Divider()
        Button {
          Task { await model.refreshDocument() }
        } label: {
          label("Reload from Machine", "arrow.clockwise")
        }
        Divider()
        Button(action: onNewTab) { label("New Tab", "plus.square.on.square") }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuIndicator(.hidden)
      .accessibilityLabel("File Actions")
      .help("File Actions")
    }

    private var previewToggleTitle: String {
      model.editor.preview ? "Show Editor" : "Show Preview"
    }

    private var previewToggleIcon: String {
      model.editor.preview ? "pencil" : "eye"
    }

    private func label(_ title: String, _ systemImage: String) -> some View {
      Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
    }
  }
#endif
