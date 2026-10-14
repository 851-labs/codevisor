import CodevisorCore
import SwiftUI

public struct ReviewPaneToolbar: ToolbarContent {
  private let model: ReviewPaneModel
  private let title: String

  public init(model: ReviewPaneModel, title: String) {
    self.model = model
    self.title = title
  }

  public var body: some ToolbarContent {
    #if canImport(AppKit)
      ToolbarItem(id: "review.title", placement: .navigation) {
        ReviewToolbarTitle(model: model, title: title)
          .padding(.leading, 12)
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarSpacer(.flexible)
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          ReviewModePicker(model: model)
        } label: {
          Text(model.mode.title)
        }
        .accessibilityLabel("Compare, \(model.mode.title)")
        .help("Choose Which Changes to Review")
        if model.mode == .branch {
          ReviewBaseAutocomplete(model: model)
        }
      }
    #else
      ToolbarItem(id: "review.title", placement: .principal) {
        ReviewToolbarTitle(model: model, title: title)
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarItem(id: "review.options", placement: .topBarTrailing) {
        ReviewOptionsMenu(model: model)
      }
    #endif
  }
}

struct ReviewToolbarTitle: View {
  let model: ReviewPaneModel
  let title: String

  var body: some View {
    #if canImport(AppKit)
      HStack(spacing: 8) { content }
        .accessibilityElement(children: .combine)
    #else
      VStack(spacing: 1) { content }
        .accessibilityElement(children: .combine)
    #endif
  }

  @ViewBuilder
  private var content: some View {
    Text(title)
      .font(.headline)
      .lineLimit(1)
    if model.failure == nil, !model.files.isEmpty {
      DiffCounter(totals: model.totals)
    }
  }
}

struct ReviewModePicker: View {
  let model: ReviewPaneModel

  var body: some View {
    Picker(
      "Compare",
      selection: Binding(get: { model.mode }, set: { model.setMode($0) })
    ) {
      ForEach(ServerGitDiffMode.reviewOrder, id: \.self) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.inline)
  }
}

struct ReviewOptionsMenu: View {
  let model: ReviewPaneModel

  var body: some View {
    Menu {
      ReviewModePicker(model: model)
      if model.mode == .branch {
        Section {
          Button {
            model.showsBranchPicker = true
          } label: {
            Text("Base Branch")
            Text(model.baseDisplayName)
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("Review Options")
    .task { await model.loadRefs() }
  }
}

struct ReviewBranchPicker: View {
  let model: ReviewPaneModel

  var body: some View {
    Picker(
      "Base Branch",
      selection: Binding(get: { model.baseDisplayName }, set: { model.setBase($0) })
    ) {
      ForEach(local) { branch in
        Text(branch.name).tag(branch.name)
      }
      if !remote.isEmpty {
        Section("Remote") {
          ForEach(remote) { branch in
            Text(branch.name).tag(branch.name)
          }
        }
      }
    }
    .pickerStyle(.inline)
  }

  private var local: [ServerGitRefs.Branch] { model.branchChoices.filter { !$0.remote } }
  private var remote: [ServerGitRefs.Branch] { model.branchChoices.filter(\.remote) }
}
