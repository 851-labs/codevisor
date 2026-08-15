import Foundation
import ACPKit

extension SessionController {
    // MARK: - Analytics

    func captureChatCreatedIfNeeded(model: SessionModel, harnessId: String) {
        guard pendingNewChatAnalytics else { return }
        pendingNewChatAnalytics = false
        var properties = analyticsSessionProperties(model: model)
        properties["harness_id"] = .string(harnessId)
        properties["uses_worktree"] = .boolean(serverSession?.worktreeName != nil)
        properties["client"] = .string(project.serverId == "local" ? "local" : "remote")
        AnalyticsClient.shared.capture(.chatCreated, properties: properties)
    }

    func captureMessageSent(model: SessionModel?, attachmentCount: Int, isQueued: Bool) {
        var properties = analyticsSessionProperties(model: model)
        properties["attachment_count"] = .integer(attachmentCount)
        properties["is_queued"] = .boolean(isQueued)
        AnalyticsClient.shared.capture(.messageSent, properties: properties)
    }

    func captureModelSelected(modelId: String, previousModelId: String?) {
        var properties = analyticsSessionProperties(model: model)
        properties["model_id"] = .string(modelId)
        if let previousModelId {
            properties["previous_model_id"] = .string(previousModelId)
        }
        AnalyticsClient.shared.capture(.modelSelected, properties: properties)
    }

    func captureHarnessSelected(harnessId: String, previousHarnessId: String?) {
        var properties = analyticsSessionProperties(model: model)
        properties["harness_id"] = .string(harnessId)
        if let previousHarnessId {
            properties["previous_harness_id"] = .string(previousHarnessId)
        }
        AnalyticsClient.shared.capture(.harnessSelected, properties: properties)
    }

    func captureTurnEnded(_ model: SessionModel) {
        guard case let .assistant(message) = model.activeItem else { return }

        let turn = message.turn
        let currentUsage = model.usage
        let previousUsage = analyticsUsageBaseline
        analyticsUsageBaseline = currentUsage

        var properties = analyticsSessionProperties(model: model)
        if let stopReason = turn.stopReason?.rawValue {
            properties["stop_reason"] = .string(stopReason)
        }
        if let duration = turn.duration {
            properties["duration_ms"] = .integer(Int((duration * 1_000).rounded()))
        }
        properties["tool_call_count"] = .integer(turn.allToolCalls.count)

        addTokenBucket(
            key: "input_token_bucket",
            current: currentUsage?.inputTokens,
            previous: previousUsage?.inputTokens,
            to: &properties
        )
        addTokenBucket(
            key: "output_token_bucket",
            current: currentUsage?.outputTokens,
            previous: previousUsage?.outputTokens,
            to: &properties
        )
        addTokenBucket(
            key: "total_token_bucket",
            current: currentUsage?.totalTokens,
            previous: previousUsage?.totalTokens,
            to: &properties
        )

        if let cost = currentUsage?.cost {
            let previousCost = previousUsage?.cost
            let amount =
                previousCost?.currency == cost.currency
                ? max(0, cost.amount - (previousCost?.amount ?? 0))
                : cost.amount
            properties["cost"] = .double(amount)
            properties["cost_currency"] = .string(cost.currency)
            if let kind = cost.kind?.rawValue {
                properties["cost_kind"] = .string(kind)
            }
        }

        if model.errorMessage != nil {
            properties["error_kind"] = .string(
                model.errorRequiresHarnessAuthentication ? "authentication_required" : "runtime_error"
            )
            AnalyticsClient.shared.capture(.turnFailed, properties: properties)
        } else {
            AnalyticsClient.shared.capture(.turnCompleted, properties: properties)
        }
    }

    private func analyticsSessionProperties(model: SessionModel?) -> [String: AnalyticsPropertyValue] {
        var properties: [String: AnalyticsPropertyValue] = [:]
        if let sessionId = serverSession?.id.uuidString {
            properties["chat_id"] = .string(sessionId)
        }
        if let harnessId = connectedHarnessId ?? selectedHarnessId ?? serverSession?.harnessId,
            !harnessId.isEmpty
        {
            properties["harness_id"] = .string(harnessId)
        }
        let modelId =
            model?.configOptions.first {
                $0.category == SessionConfigOption.Category.model
            }?.currentValue ?? modelOption?.currentValue
        if let modelId, !modelId.isEmpty {
            properties["model_id"] = .string(modelId)
        }
        if let mode = model?.modeState?.currentModeId ?? modeState?.currentModeId,
            !mode.isEmpty
        {
            properties["mode"] = .string(mode)
        }
        return properties
    }

    private func addTokenBucket(
        key: String,
        current: UInt64?,
        previous: UInt64?,
        to properties: inout [String: AnalyticsPropertyValue]
    ) {
        guard let current else { return }
        let delta = previous.map { current >= $0 ? current - $0 : current } ?? current
        if let bucket = AnalyticsClient.tokenBucket(delta) {
            properties[key] = .string(bucket)
        }
    }
}
