import Foundation
import Observation

@MainActor
@Observable
public final class FileLightbox {
  public private(set) var files: [ViewableFile] = []
  public private(set) var index = 0
  @ObservationIgnored public private(set) var opener: FileOpener?
  @ObservationIgnored private var pages: [String: FilePaneModel] = [:]

  public init() {}

  public var isPresented: Bool { !files.isEmpty }
  public var canPage: Bool { files.count > 1 }

  public var current: ViewableFile? {
    files.indices.contains(index) ? files[index] : nil
  }

  public func present(_ file: ViewableFile, among group: [ViewableFile], opener: FileOpener) {
    closePages()
    self.opener = opener
    files = group
    index = group.firstIndex(of: file) ?? 0
  }

  public func dismiss() {
    guard isPresented else { return }

    files = []
    index = 0
    opener = nil
    closePages()
  }

  public func showNext() { step(by: 1) }

  public func showPrevious() { step(by: -1) }

  public func show(_ file: ViewableFile) {
    guard let position = files.firstIndex(of: file) else { return }
    index = position
  }

  public func page(for file: ViewableFile) -> FilePaneModel? {
    if let page = pages[file.id] { return page }
    guard let opener, let path = opener.path(of: file) else { return nil }

    let page = FilePaneModel(
      id: UUID(), path: path, rootPath: opener.site.rootPath, machineId: opener.site.machineId,
      client: opener.site.client, access: .viewing)
    page.editor.reveal(file.target, rendered: FileDocumentLocation.opensRendered(file.target))
    pages[file.id] = page
    return page
  }

  private func step(by offset: Int) {
    guard canPage else { return }
    index = (index + offset + files.count) % files.count
  }

  private func closePages() {
    for page in pages.values { page.close() }
    pages = [:]
  }
}
