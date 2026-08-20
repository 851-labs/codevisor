import CodevisorCore
import CodevisorUI
import SwiftUI

/// A compact, touch-sized summary above the composer. Queue management lives
/// in a sheet so editing and deletion never depend on tiny inline controls.
struct IOSPromptQueueAccessory: View {
    @Bindable var controller: SessionController
    let glassNamespace: Namespace.ID
    @State private var isPresentingQueue = false

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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Queue")
                        .font(.caption.weight(.semibold))
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                if let firstItem {
                    Text(firstItem.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
        .sheet(isPresented: $isPresentingQueue) {
            IOSPromptQueueSheet(controller: controller)
        }
        .onChange(of: controller.queuedPrompts.isEmpty) { _, isEmpty in
            if isEmpty {
                isPresentingQueue = false
            }
        }
    }
}

private struct IOSPromptQueueSheet: View {
    private enum Destination: Hashable {
        case edit(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: SessionController
    @State private var path: [Destination] = []
    @State private var pendingDeleteID: String?
    @State private var deletingIDs: Set<String> = []
    @State private var mutationError: String?

    private var pendingDeleteItem: ServerPromptQueueItem? {
        guard let pendingDeleteID else { return nil }
        return controller.queuedPrompts.first { $0.id == pendingDeleteID }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(Array(controller.queuedPrompts.enumerated()), id: \.element.id) {
                        index, item in
                        queueRow(item, position: index)
                    }
                } footer: {
                    Text("Messages are sent in order as the agent becomes available.")
                }
            }
            .navigationTitle("Queued Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                destinationView(destination)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(!deletingIDs.isEmpty)
        .confirmationDialog(
            "Remove queued message?",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteItem
        ) { item in
            Button("Remove Message", role: .destructive) {
                delete(item)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: { _ in
            Text("This message will not be sent. This action cannot be undone.")
        }
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
        .onChange(of: controller.queuedPrompts.map(\.id)) { _, ids in
            reconcile(with: ids)
        }
    }

    private func queueRow(_ item: ServerPromptQueueItem, position: Int) -> some View {
        Button {
            path.append(.edit(item.id))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                queuePositionIcon(position)

                VStack(alignment: .leading, spacing: 5) {
                    Text(position == 0 ? "Next" : "Message \(position + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    if let attachments = item.attachments, !attachments.isEmpty {
                        Label(attachmentText(attachments.count), systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if deletingIDs.contains(item.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: Typography.minimumInteractiveTargetSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(deletingIDs.contains(item.id))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                pendingDeleteID = item.id
            }
            Button("Edit", systemImage: "pencil") {
                path.append(.edit(item.id))
            }
            .tint(.accentColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(position == 0 ? "Next queued message" : "Queued message \(position + 1)")
        .accessibilityValue(accessibilityValue(for: item))
        .accessibilityHint("Double-tap to edit")
        .accessibilityAction(named: "Edit") {
            path.append(.edit(item.id))
        }
        .accessibilityAction(named: "Remove") {
            pendingDeleteID = item.id
        }
    }

    @ViewBuilder
    private func queuePositionIcon(_ position: Int) -> some View {
        if position == 0 {
            Image(systemName: "arrow.right.circle.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .scaledFrame(width: 22, relativeTo: .body)
        } else {
            Image(systemName: "circle")
                .font(.body)
                .foregroundStyle(.tertiary)
                .scaledFrame(width: 22, relativeTo: .body)
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
        pendingDeleteID = nil
        guard deletingIDs.insert(item.id).inserted else { return }

        Task {
            let didDelete = await controller.deleteQueuedPrompt(id: item.id)
            if !didDelete {
                deletingIDs.remove(item.id)
                mutationError = controller.errorMessage ?? "The queued message could not be removed."
            }
        }
    }

    private func reconcile(with ids: [String]) {
        let currentIDs = Set(ids)
        deletingIDs.formIntersection(currentIDs)

        if let pendingDeleteID, !currentIDs.contains(pendingDeleteID) {
            self.pendingDeleteID = nil
        }

        if case .edit(let editingID) = path.last, !currentIDs.contains(editingID) {
            path.removeLast()
        }

        if ids.isEmpty {
            dismiss()
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
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinish() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving queued message")
                } else {
                    Button("Save") { save() }
                        .disabled(trimmedText.isEmpty || trimmedText == item.text)
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
