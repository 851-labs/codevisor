import SwiftUI

/// Native toolbar content used by the active file pane on each platform.
public struct FilePaneToolbar: ToolbarContent {
  private let model: FilePaneModel
  private let onNewTab: () -> Void

  public init(model: FilePaneModel, onNewTab: @escaping () -> Void) {
    self.model = model
    self.onNewTab = onNewTab
  }

  public var body: some ToolbarContent {
    #if canImport(AppKit)
      ToolbarItem(id: "file.title", placement: .navigation) {
        Group {
          if model.isBrowsing {
            Text(model.title).font(.headline)
          } else {
            FilePaneTitleButton(model: model)
          }
        }
        // Match the native navigation title's inset from the sidebar divider.
        .padding(.leading, 12)
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarSpacer(.flexible)
    #else
      ToolbarItem(id: "file.title", placement: .principal) {
        if model.isBrowsing {
          Text(model.title).font(.headline)
        } else {
          FilePaneTitleButton(model: model)
        }
      }
      .sharedBackgroundVisibility(.hidden)
    #endif
    ToolbarItemGroup(placement: .primaryAction) {
      if !model.isBrowsing {
        if model.document.isMarkdown {
          Button {
            model.editor.preview.toggle()
          } label: {
            Label(model.editor.preview ? "Edit" : "Preview", systemImage: model.editor.preview ? "pencil" : "eye")
          }
          .accessibilityLabel(model.editor.preview ? "Show Editor" : "Show Preview")
          .help(model.editor.preview ? "Show Editor" : "Show Preview")
        }
        FilePaneActions(model: model, onNewTab: onNewTab)
      }
    }
  }
}

/// The document title doubles as the Open File trigger. On Mac the picker
/// is a popover anchored here; on iPhone it is a sheet the pane presents.
private struct FilePaneTitleButton: View {
  @Bindable var model: FilePaneModel

  var body: some View {
    Button {
      model.openExplorer()
    } label: {
      HStack(spacing: 6) {
        Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
      }
      #if canImport(AppKit)
        .frame(maxWidth: 260, alignment: .leading)
      #else
        .frame(maxWidth: 260)
      #endif
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(model.title), Open File")
    .help("Open File")
    #if canImport(AppKit)
      .popover(isPresented: $model.showsExplorer, arrowEdge: .bottom) {
        MacFileOpenPopover(model: model)
      }
    #endif
  }
}

private struct FilePaneActions: View {
  @Bindable var model: FilePaneModel
  let onNewTab: () -> Void

  /// iOS draws every New Tab action with the stacked-squares glyph; the
  /// Mac keeps its plain plus.
  static var newTabSymbol: String {
    #if os(iOS)
      "plus.square.on.square"
    #else
      "plus"
    #endif
  }

  var body: some View {
    Menu {
      Button("Open File", systemImage: "doc.text.magnifyingglass") { model.openExplorer() }
        .keyboardShortcut("o", modifiers: .command)
      if model.document.isMarkdown {
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
      Button("Reload from Machine", systemImage: "arrow.clockwise") { Task { await model.document.refresh() } }
      Divider()
      Button("New Tab", systemImage: Self.newTabSymbol) { onNewTab() }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("File Actions")
    .help("File Actions")
  }
}
