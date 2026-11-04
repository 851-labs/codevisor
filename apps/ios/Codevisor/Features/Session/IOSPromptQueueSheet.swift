import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSPromptQueueSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var controller: SessionController
  @State private var displayedQueue: [ServerPromptQueueItem]
  @State private var busyIDs: Set<String> = []
  @State private var isReordering = false
  @State private var mutationError: String?

  init(controller: SessionController) {
    self.controller = controller
    _displayedQueue = State(initialValue: controller.queuedPrompts)
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(displayedQueue) { item in
          IOSPromptQueueRow(
            item: item,
            canSendNow: controller.canSendQueuedPromptNow,
            isBusy: busyIDs.contains(item.id) || isReordering,
            actions: rowActions(for: item)
          )
        }
        .onMove(perform: moveQueue)
        ForEach(controller.unsentQueuedMessages) { message in
          IOSPromptQueueUnsentRow(
            message: message,
            retry: { Task { await controller.retryUnsentMessage(id: message.id) } },
            delete: { controller.deleteUnsentMessage(id: message.id) }
          )
          .moveDisabled(true)
        }
      }
      .contentMargins(.top, 8, for: .scrollContent)
      .navigationTitle("Queued")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(isReordering)
    .alert(
      "Couldn't Update Queue",
      isPresented: Binding(
        get: { mutationError != nil },
        set: { if !$0 { mutationError = nil } }
      )
    ) {
      Button("OK") { mutationError = nil }
    } message: {
      Text(mutationError ?? "Please try again.")
    }
    .onChange(of: controller.queuedPrompts) { _, queue in
      reconcile(with: queue)
    }
    .onChange(of: controller.hasQueuedMessages) { _, hasQueuedMessages in
      if !hasQueuedMessages { dismiss() }
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Close") { dismiss() }
    }
    ToolbarItem(placement: .primaryAction) {
      EditButton()
        .disabled(displayedQueue.count < 2 || isReordering)
    }
  }

  private func rowActions(for item: ServerPromptQueueItem) -> IOSPromptQueueRow.Actions {
    IOSPromptQueueRow.Actions(
      edit: { beginEditing(item) },
      sendNow: { sendNow(item) },
      remove: { remove(item) }
    )
  }

  private func beginEditing(_ item: ServerPromptQueueItem) {
    controller.beginEditingQueuedPrompt(item)
    dismiss()
  }

  private func sendNow(_ item: ServerPromptQueueItem) {
    perform(on: item.id, failure: "The queued message could not be sent.") {
      await controller.sendQueuedPromptNow(id: item.id)
    }
  }

  private func remove(_ item: ServerPromptQueueItem) {
    perform(on: item.id, failure: "The queued message could not be removed.") {
      await controller.deleteQueuedPrompt(id: item.id)
    }
  }

  private func perform(on id: String, failure: String, _ mutation: @escaping () async -> Bool) {
    guard busyIDs.insert(id).inserted else { return }
    Task {
      let succeeded = await mutation()
      busyIDs.remove(id)
      if !succeeded, isStillQueued(id) { mutationError = controller.errorMessage ?? failure }
    }
  }

  private func isStillQueued(_ id: String) -> Bool {
    controller.queuedPrompts.contains { $0.id == id }
  }

  private func moveQueue(from source: IndexSet, to destination: Int) {
    guard !isReordering, busyIDs.isEmpty else { return }
    displayedQueue.move(fromOffsets: source, toOffset: destination)
    let orderedIDs = displayedQueue.map(\.id)
    isReordering = true

    Task {
      let didReorder = await controller.reorderQueuedPrompts(ids: orderedIDs)
      isReordering = false
      if !didReorder {
        displayedQueue = controller.queuedPrompts
        mutationError = controller.errorMessage ?? "The queue could not be reordered."
      }
    }
  }

  private func reconcile(with queue: [ServerPromptQueueItem]) {
    displayedQueue = queue
    let currentIDs = Set(queue.map(\.id))
    busyIDs.formIntersection(currentIDs)
    if !controller.hasQueuedMessages { dismiss() }
  }
}
