import CodevisorCore
import SwiftUI

extension EnvironmentValues {
  @Entry public var openFileDocument: ((String) -> Bool)?
}

/// Content only. The owning workspace supplies the native toolbar.
public struct FilePaneView: View {
  @Bindable private var model: FilePaneModel
  @Environment(\.theme) private var theme
  @Environment(\.openFileDocument) private var openFile
  @Environment(\.scenePhase) private var scenePhase

  public init(model: FilePaneModel) { self.model = model }

  private var document: FileDocumentModel { model.document }

  public var body: some View {
    VStack(spacing: 0) {
      if model.showsFind { FileFindBar(model: model) }
      if document.conflict != nil {
        HStack {
          Label("This file changed elsewhere", systemImage: "exclamationmark.triangle")
            .font(.callout)
          Spacer()
          Button("Review Changes") { model.showsConflict = true }
        }
        .padding(12).background(.orange.opacity(0.12))
      }
      if let error = document.error ?? document.draftError {
        HStack {
          Label(error, systemImage: "exclamationmark.circle").font(.callout)
          Spacer()
          Button("Retry") { Task { await document.retry() } }
        }.padding(12).background(.orange.opacity(0.08))
      }
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Same surface rule as every other pane: system themes reveal the
    // native window backdrop; custom palettes paint their editor color.
    .background(theme.contentBackground)
    .task(id: model.path) {
      guard !model.isBrowsing else { return }
      let active = document
      defer { active.flushAutosave() }
      await active.refresh()
      if active.snapshot != nil { model.recordRecent() }
      guard !model.path.hasPrefix("https://attachments.codevisor.invalid/") else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { break }
        if scenePhase == .active { await active.refresh() }
      }
    }
    .onChange(of: model.editor.preview) { _, preview in
      if preview { model.editor.resignFocus() }
    }
    .onChange(of: scenePhase) { _, phase in
      document.flushAutosave()
      if phase == .active && !model.isBrowsing { Task { await document.refresh() } }
    }
    .onDisappear { document.flushAutosave() }
    .alert("Go to Line", isPresented: $model.showsGoToLine) {
      TextField("Line number", text: $model.lineText)
      Button("Go") { model.editor.goToLine(Int(model.lineText) ?? 1) }
      Button("Cancel", role: .cancel) {}
    }
    #if !canImport(AppKit)
      // On Mac the picker is a popover from the title (see FilePaneToolbar).
      .sheet(isPresented: $model.showsExplorer) {
        FileBrowserSheet(model: model)
        .buttonStyle(.automatic)
        .environment(\.closeFileBrowser, { model.showsExplorer = false })
      }
    #endif
    .sheet(isPresented: $model.showsConflict) { FileConflictView(model: model) }
  }

  @ViewBuilder private var content: some View {
    if model.isBrowsing {
      #if canImport(AppKit)
        MacFileOpenPage(model: model)
      #else
        FileBrowserView(model: model)
      #endif
    } else if document.snapshot == nil {
      if document.isLoading {
        ProgressView("Opening file…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "File unavailable", systemImage: "doc.questionmark", description: Text("Check the connection and try again."))
      }
    } else if document.snapshot?.content == nil {
      FileMediaPreview(
        path: model.path, client: model.client, size: document.snapshot?.size ?? 0
      )
      .id(document.snapshot?.version)
    } else {
      ZStack {
        FileSourceEditor(session: model.editor)
          .id(model.path)
          .opacity(model.editor.preview ? 0 : 1)
          .allowsHitTesting(!model.editor.preview)
          .accessibilityHidden(model.editor.preview)
        if model.editor.preview {
          FileMarkdownPreview(document: document, client: model.client) { target in
            if openFile?(target) == true { return true }
            guard let path = FileDocumentLocation.resolve(target, relativeTo: model.rootPath) else { return false }
            model.navigate(to: path)
            if let line = FileDocumentLocation.line(target) { model.editor.goToLine(line) }
            return true
          }
        }
      }
    }
  }

}
