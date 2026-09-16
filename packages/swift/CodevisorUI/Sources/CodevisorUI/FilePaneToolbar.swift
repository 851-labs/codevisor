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
          Text("Files").font(.headline)
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

private struct FilePaneTitleButton: View {
  @Bindable var model: FilePaneModel

  var body: some View {
    Button {
      model.showsExplorer = true
    } label: {
      HStack(spacing: 6) {
        Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
        if !model.isBrowsing {
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
      }
      #if canImport(AppKit)
        .frame(maxWidth: 260, alignment: .leading)
      #else
        .frame(maxWidth: 260)
      #endif
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.isBrowsing)
    .accessibilityLabel("\(model.title), Browse Files")
    .help("Browse workspace files")

  }
}

struct FileBrowserSheet: View {
  let model: FilePaneModel

  var body: some View {
    #if canImport(AppKit)
      NavigationStack {
        FileBrowserView(model: model)
          .scenePadding(.top)
      }
      .frame(width: 560, height: 360)
    #else
      NavigationStack {
        FileBrowserView(model: model)
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    #endif
  }
}

private struct FilePaneActions: View {
  @Bindable var model: FilePaneModel
  let onNewTab: () -> Void

  var body: some View {
    Menu {
      Button("Open File…", systemImage: "folder") { model.showsExplorer = true }
        .keyboardShortcut("o", modifiers: .command)
      if model.document.isMarkdown {
        Button(
          model.editor.preview ? "Show Editor" : "Show Preview",
          systemImage: model.editor.preview ? "pencil" : "eye"
        ) {
          model.editor.preview.toggle()
        }
      }
      Divider()
      if model.document.snapshot?.content != nil {
        Button("Find…", systemImage: "magnifyingglass") {
          model.showsFind.toggle()
          model.editor.preview = false
        }
        .keyboardShortcut("f", modifiers: .command)
        Menu("Editor") {
          Button("Go to Line…", systemImage: "number") { model.showsGoToLine = true }
            .keyboardShortcut("g", modifiers: .control)
          #if canImport(AppKit)
            Toggle(
              "Wrap Lines", isOn: Binding(get: { model.editor.wrapsLines }, set: { model.editor.wrapsLines = $0 })
            )
          #endif
          Toggle(
            "Line Numbers",
            isOn: Binding(get: { model.editor.showsLineNumbers }, set: { model.editor.showsLineNumbers = $0 }))
          Divider()
          Button("Undo", systemImage: "arrow.uturn.backward") { model.editor.undo() }
          Button("Redo", systemImage: "arrow.uturn.forward") { model.editor.redo() }
        }
      }
      Button("File Info", systemImage: "info.circle") { model.showsDetails = true }
      Button("Reload from Machine", systemImage: "arrow.clockwise") { Task { await model.document.refresh() } }
      Divider()
      Button("New Tab", systemImage: "plus") { onNewTab() }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("File Actions")
    .help("File Actions")
  }
}

/// A temporary browser, presented from the title or as an empty file pane.
struct FileBrowserView: View {
  let model: FilePaneModel
  @Environment(\.openFileDocument) private var openFile

  var body: some View {
    FileExplorerView(
      model: model.explorer, selectedPath: model.path,
      open: { model.navigate(to: $0) },
      openInTab: { target in
        model.showsExplorer = false
        _ = openFile?(target)
      })
  }
}
