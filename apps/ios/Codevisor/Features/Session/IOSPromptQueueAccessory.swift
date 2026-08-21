import CodevisorCore
import CodevisorUI
import SwiftUI

/// A compact, touch-sized summary above the composer. Queue management lives
/// in a sheet so editing and deletion never depend on tiny inline controls.
struct IOSPromptQueueAccessory: View {
    @Bindable var controller: SessionController
    let glassNamespace: Namespace.ID
    @Binding var isPresentingQueue: Bool

    private var firstItem: ServerPromptQueueItem? {
        controller.queuedPrompts.first
    }

    private var countText: String {
        let count = controller.queuedPrompts.count
        return count == 1 ? "1 message" : "\(count) messages"
    }

    var body: some View {
        Button {
            isPresentingQueue = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let firstItem {
                    Text(firstItem.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if controller.queuedPrompts.count > 1 {
                    Text("(\(controller.queuedPrompts.count))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: Typography.minimumInteractiveTargetSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
            id: .queue,
            in: glassNamespace
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Queue, \(countText)")
        .accessibilityValue(firstItem.map { "Next: \($0.text)" } ?? "")
        .accessibilityHint("Opens queued message management")
    }
}

struct IOSPromptQueueSheet: View {
    private enum Destination: Hashable {
        case edit(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: SessionController
    @State private var path: [Destination] = []
    @State private var deletingIDs: Set<String> = []
    @State private var displayedQueue: [ServerPromptQueueItem]
    @State private var isReordering = false
    @State private var mutationError: String?

    init(controller: SessionController) {
        self.controller = controller
        _displayedQueue = State(initialValue: controller.queuedPrompts)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(displayedQueue) { item in
                    queueRow(item)
                }
                .onMove(perform: moveQueue)
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                        .disabled(displayedQueue.count < 2 || isReordering)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                destinationView(destination)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(!deletingIDs.isEmpty || isReordering)
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
            displayedQueue = queue
            reconcile(with: queue.map(\.id))
        }
    }

    private func queueRow(_ item: ServerPromptQueueItem) -> some View {
        Button {
            path.append(.edit(item.id))
        } label: {
            HStack(spacing: 8) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: Typography.minimumInteractiveTargetSize,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(deletingIDs.contains(item.id) || isReordering)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                delete(item)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Queued message")
        .accessibilityValue(accessibilityValue(for: item))
        .accessibilityHint("Double-tap to edit")
        .accessibilityAction(named: "Edit") {
            path.append(.edit(item.id))
        }
        .accessibilityAction(named: "Remove") {
            delete(item)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .edit(let id):
            if let item = controller.queuedPrompts.first(where: { $0.id == id }) {
                IOSQueuedPromptEditor(controller: controller, item: item) {
                    if !path.isEmpty {
                        path.removeLast()
                    }
                }
            } else {
                ContentUnavailableView(
                    "Message No Longer Queued",
                    systemImage: "text.badge.xmark",
                    description: Text("The queue changed on another device.")
                )
                .navigationTitle("Edit Message")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func delete(_ item: ServerPromptQueueItem) {
        guard deletingIDs.insert(item.id).inserted else { return }

        Task {
            let didDelete = await controller.deleteQueuedPrompt(id: item.id)
            if !didDelete {
                deletingIDs.remove(item.id)
                mutationError = controller.errorMessage ?? "The queued message could not be removed."
            }
        }
    }

    private func moveQueue(from source: IndexSet, to destination: Int) {
        guard !isReordering, deletingIDs.isEmpty else { return }
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

    private func reconcile(with ids: [String]) {
        let currentIDs = Set(ids)
        deletingIDs.formIntersection(currentIDs)

        if case .edit(let editingID) = path.last, !currentIDs.contains(editingID) {
            path.removeLast()
        }
    }

    private func attachmentText(_ count: Int) -> String {
        count == 1 ? "1 attachment" : "\(count) attachments"
    }

    private func accessibilityValue(for item: ServerPromptQueueItem) -> String {
        guard let count = item.attachments?.count, count > 0 else { return item.text }
        return "\(item.text), \(attachmentText(count))"
    }
}

private struct IOSQueuedPromptEditor: View {
    @Bindable var controller: SessionController
    let item: ServerPromptQueueItem
    let onFinish: () -> Void
    @State private var text: String
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var isEditorFocused: Bool

    init(
        controller: SessionController,
        item: ServerPromptQueueItem,
        onFinish: @escaping () -> Void
    ) {
        self.controller = controller
        self.item = item
        self.onFinish = onFinish
        _text = State(initialValue: item.text)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Message") {
                TextEditor(text: $text)
                    .focused($isEditorFocused)
                    .frame(minHeight: 180, alignment: .topLeading)
                    .accessibilityLabel("Queued message")
            }

            if let attachments = item.attachments, !attachments.isEmpty {
                Section {
                    ForEach(attachments) { attachment in
                        Label(attachment.name, systemImage: attachmentSystemImage(attachment))
                    }
                } header: {
                    Text("Attachments")
                } footer: {
                    Text("Attachments stay with the queued message and cannot be changed here.")
                }
            }
        }
        .navigationTitle("Edit Message")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving queued message")
                } else {
                    Button("Save") { save() }
                        .disabled(trimmedText.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .alert(
            "Couldn't Save Message",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Please try again.")
        }
        .task {
            isEditorFocused = true
        }
    }

    private func save() {
        guard !trimmedText.isEmpty, !isSaving else { return }
        isSaving = true

        Task {
            let didSave = await controller.updateQueuedPrompt(id: item.id, text: trimmedText)
            isSaving = false
            if didSave {
                onFinish()
            } else {
                saveError = controller.errorMessage ?? "The queued message could not be saved."
            }
        }
    }

    private func attachmentSystemImage(_ attachment: ServerAttachmentRef) -> String {
        attachment.kind == .image ? "photo" : "doc"
    }
}
