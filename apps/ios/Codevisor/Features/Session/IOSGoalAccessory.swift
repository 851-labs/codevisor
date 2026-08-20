import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Touch-sized goal summary above the composer. The compact surface is one
/// target; lifecycle controls move into a standard sheet instead of competing
/// for horizontal room as small icon buttons.
struct IOSGoalAccessory: View {
    @Bindable var controller: SessionController
    let goal: SessionGoal
    let isDraft: Bool
    let glassNamespace: Namespace.ID
    @State private var isPresentingGoal = false

    private var statusText: String {
        GoalPresentation.statusText(for: goal.status)
    }

    var body: some View {
        Button {
            isPresentingGoal = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "target")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(goal.status == .active ? Color.accentColor : Color.secondary)
                    .scaledFrame(width: 22, relativeTo: .callout)

                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.objective)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(statusText)
                        if let usageText = GoalPresentation.usageText(for: goal) {
                            Text("·")
                            Text(usageText)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(10)
            .frame(
                maxWidth: .infinity,
                minHeight: Typography.minimumInteractiveTargetSize,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
            id: .goal,
            in: glassNamespace
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Goal: \(goal.objective)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens goal controls")
        .sheet(isPresented: $isPresentingGoal) {
            IOSGoalManagementSheet(
                controller: controller,
                goal: goal,
                isDraft: isDraft
            )
        }
    }

    private var accessibilityValue: String {
        let usage = GoalPresentation.usageText(for: goal)
        return [statusText, usage].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct IOSGoalManagementSheet: View {
    private enum Mutation: Equatable {
        case pause
        case resume
        case clear
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: SessionController
    let goal: SessionGoal
    let isDraft: Bool
    @State private var mutation: Mutation?
    @State private var mutationError: String?
    @State private var isConfirmingClear = false

    private var statusText: String {
        GoalPresentation.statusText(for: goal.status)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Objective") {
                    Text(goal.objective)
                        .font(.body)
                        .textSelection(.enabled)
                }

                Section("Status") {
                    LabeledContent("State") {
                        Label(statusText, systemImage: statusSystemImage)
                    }

                    if let activity = goal.activity, goal.status == .active {
                        LabeledContent("Activity") {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(GoalPresentation.activityText(for: activity))
                            }
                        }
                    }
                }

                if showsProgress {
                    progressSection
                }

                Section {
                    lifecycleButton

                    Button {
                        dismiss()
                        controller.editGoal()
                    } label: {
                        Label("Edit Goal", systemImage: "pencil")
                    }
                    .disabled(mutation != nil)
                }

                Section {
                    Button("Clear Goal", systemImage: "trash", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(mutation != nil)
                } footer: {
                    Text("Clearing the goal stops automatic continuation and keeps the chat history.")
                }
            }
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(mutation != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(mutation != nil)
        .confirmationDialog(
            "Clear this goal?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Goal", role: .destructive) {
                perform(.clear)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent stops working toward “\(goal.objective)”.")
        }
        .alert(
            "Couldn't Update Goal",
            isPresented: Binding(
                get: { mutationError != nil },
                set: { if !$0 { mutationError = nil } }
            )
        ) {
            Button("OK") { mutationError = nil }
        } message: {
            Text(mutationError ?? "Please try again.")
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        Section("Progress") {
            if goal.tokensUsed > 0 {
                LabeledContent("Tokens", value: GoalPresentation.tokens(goal.tokensUsed))
            }
            if let budget = goal.tokenBudget {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Budget", value: GoalPresentation.tokens(budget))
                    ProgressView(
                        value: min(Double(goal.tokensUsed), Double(budget)),
                        total: Double(max(1, budget))
                    )
                    .accessibilityLabel("Goal token budget")
                    .accessibilityValue("\(goal.tokensUsed) of \(budget) tokens used")
                }
            }
            if goal.timeUsedSeconds > 0 {
                LabeledContent("Elapsed", value: GoalPresentation.elapsed(goal.timeUsedSeconds))
            }
        }
    }

    @ViewBuilder
    private var lifecycleButton: some View {
        if !isDraft, goal.status == .active {
            Button {
                perform(.pause)
            } label: {
                mutationLabel(
                    title: "Pause Goal",
                    systemImage: "pause.fill",
                    isPending: mutation == .pause
                )
            }
            .disabled(mutation != nil)
        } else if !isDraft, goal.status != .complete {
            Button {
                perform(.resume)
            } label: {
                mutationLabel(
                    title: "Resume Goal",
                    systemImage: "play.fill",
                    isPending: mutation == .resume
                )
            }
            .disabled(mutation != nil)
        }
    }

    private func mutationLabel(title: String, systemImage: String, isPending: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating goal")
            }
        }
    }

    private var showsProgress: Bool {
        goal.tokensUsed > 0 || goal.tokenBudget != nil || goal.timeUsedSeconds > 0
    }

    private var statusSystemImage: String {
        switch goal.status {
        case .active: "target"
        case .paused: "pause.circle"
        case .blocked: "exclamationmark.octagon"
        case .usageLimited: "gauge.with.dots.needle.33percent"
        case .budgetLimited: "chart.pie"
        case .complete: "checkmark.circle"
        }
    }

    private func perform(_ requestedMutation: Mutation) {
        guard mutation == nil else { return }
        mutation = requestedMutation

        Task {
            let succeeded =
                switch requestedMutation {
                case .pause: await controller.pauseGoal()
                case .resume: await controller.resumeGoal()
                case .clear: await controller.clearGoal()
                }
            mutation = nil
            if succeeded {
                if requestedMutation == .clear {
                    dismiss()
                }
            } else {
                mutationError = controller.errorMessage ?? "The goal could not be updated."
            }
        }
    }
}
