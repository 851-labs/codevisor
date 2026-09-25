import CodevisorCore
import CodevisorUI
import SwiftUI

/// A spot in the remote filesystem.
struct RemoteDirectory: Hashable {
  let path: String?
  let name: String

  /// The machine's home folder (the server resolves a nil path to `~`).
  static let home = RemoteDirectory(path: nil, name: "Home")
  static let root = RemoteDirectory(path: "/", name: "/")
}

/// One level of the remote filesystem, Files-style: folder rows that push
/// deeper, git repositories badged, secondary actions behind the ellipsis
/// menu, and a fixed call to action for the current folder.
struct RemoteDirectoryScreen: View {
  @Environment(AppEnvironment.self) private var environment
  /// The machine whose filesystem is browsed.
  let serverId: String
  let directory: RemoteDirectory
  let onOpen: (RemoteDirectory) -> Void
  let onPick: (String) -> Void

  @State private var listing: ServerFsListing?
  @State private var errorMessage: String?
  @State private var showHidden = false
  @State private var showingNewFolder = false
  @State private var createdFolder: RemoteDirectory?
  @State private var loadGeneration = 0

  var body: some View {
    Group {
      if let listing {
        folderList(listing)
      } else if let errorMessage {
        ContentUnavailableView {
          Label("Couldn't Load Folder", systemImage: "folder.badge.questionmark")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try Again") {
            Task { await load() }
          }
          .buttonStyle(.borderedProminent)
        }
      } else {
        ProgressView()
      }
    }
    .task {
      guard listing == nil, errorMessage == nil else { return }
      await load()
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            showingNewFolder = true
          } label: {
            Label("New Folder…", systemImage: "folder.badge.plus")
          }
          .disabled(listing == nil)
          if directory.path == nil {
            Button {
              onOpen(.root)
            } label: {
              Label("Go to Root Folder", systemImage: "internaldrive")
            }
          }
          Divider()
          Toggle("Show Hidden Folders", isOn: $showHidden)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Folder options")
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let listing {
        Button {
          onPick(listing.path)
        } label: {
          // The app root sets a primary foreground style, which would
          // otherwise override the prominent button's white label.
          Text("Add “\(title)” as Project")
            .lineLimit(1)
            .truncationMode(.middle)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel("Add \(title) as Project")
        .buttonBorderShape(.capsule)
        .padding(.bottom, 8)
      }
    }
    // The composer's keyboard can still be up behind this sheet; keep the
    // action at the bottom instead of floating above it.
    .ignoresSafeArea(.keyboard, edges: .bottom)
    .onChange(of: showHidden) { _, _ in
      Task { await load() }
    }
    .sheet(isPresented: $showingNewFolder, onDismiss: openCreatedFolderIfNeeded) {
      if let listing {
        newFolderSheet(for: listing)
      }
    }
  }

  /// The folder's own name; the home folder is named once its listing
  /// resolves the path.
  private var title: String {
    guard directory.path == nil, let listing else { return directory.name }
    let name = (listing.path as NSString).lastPathComponent
    return name.isEmpty ? directory.name : name
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: serverId)
  }

  private var machineName: String {
    return environment.machines.machine(for: serverId)?.name
      ?? "Machine"
  }

  private func newFolderSheet(for listing: ServerFsListing) -> some View {
    let directoryClient = client
    return NewRemoteFolderSheet(
      machineName: machineName,
      parentPath: listing.path,
      existingNames: Set(listing.entries.map(\.name)),
      create: { path in try await directoryClient.createDirectory(path: path) },
      onCreated: didCreateFolder(at:)
    )
    .presentationDetents([.medium])
  }

  @MainActor
  private func didCreateFolder(at path: String) {
    let name = (path as NSString).lastPathComponent
    if var listing,
      !listing.entries.contains(where: { $0.path == path }),
      showHidden || !name.hasPrefix(".")
    {
      listing.entries.append(ServerFsEntry(name: name, path: path, isGitRepo: false))
      listing.entries.sort {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      self.listing = listing
    }
    createdFolder = RemoteDirectory(path: path, name: name.isEmpty ? path : name)
  }

  @MainActor
  private func openCreatedFolderIfNeeded() {
    guard let createdFolder else { return }
    self.createdFolder = nil
    onOpen(createdFolder)
  }

  private func folderList(_ listing: ServerFsListing) -> some View {
    List {
      ForEach(listing.entries, id: \.path) { entry in
        NavigationLink(value: RemoteDirectory(path: entry.path, name: entry.name)) {
          Label {
            HStack {
              Text(entry.name)
              if entry.isGitRepo {
                Spacer()
                Text("GIT")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(Color.secondary.opacity(0.15), in: Capsule())
              }
            }
          } icon: {
            Image(systemName: entry.isGitRepo ? "folder.fill.badge.gearshape" : "folder.fill")
              .foregroundStyle(.tint)
          }
        }
      }
    }
    .contentMargins(.bottom, 64, for: .scrollContent)
    .overlay {
      if listing.entries.isEmpty {
        Text("No Subfolders")
          .foregroundStyle(.secondary)
      }
    }
  }

  @MainActor
  private func load() async {
    loadGeneration += 1
    let requestGeneration = loadGeneration
    let requestedShowHidden = showHidden
    let directoryClient = client
    errorMessage = nil
    do {
      let loaded = try await directoryClient.listDirectory(
        path: directory.path,
        showHidden: requestedShowHidden
      )
      guard requestGeneration == loadGeneration else { return }
      listing = loaded
    } catch is CancellationError {
      return
    } catch {
      guard requestGeneration == loadGeneration else { return }
      if listing == nil {
        errorMessage = ErrorReporter.userFacingMessage(for: error)
      }
    }
  }
}
