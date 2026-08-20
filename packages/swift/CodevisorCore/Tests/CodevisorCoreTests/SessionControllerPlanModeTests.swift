import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("SessionController plan mode")
struct SessionControllerPlanModeTests {
    @Test("A draft session toggles between implementation and plan modes")
    func draftModeToggle() async {
        let controller = makeController()

        #expect(controller.hasPlanMode)
        #expect(!controller.isPlanModeOn)

        await controller.togglePlanMode()

        #expect(controller.isPlanModeOn)
        #expect(controller.modeState?.currentModeId == "plan")
        #expect(!controller.isPlanModeUpdatePending)

        await controller.togglePlanMode()

        #expect(!controller.isPlanModeOn)
        #expect(controller.modeState?.currentModeId == "build")
    }

    @Test("Entering plan mode disarms the goal composer")
    func planAndGoalAreMutuallyExclusive() async {
        let controller = makeController()
        controller.isGoalComposerArmed = true

        await controller.togglePlanMode()

        #expect(controller.isPlanModeOn)
        #expect(!controller.isGoalComposerArmed)
    }

    @Test("Pending plan approval uses the shared question shape")
    func syntheticPlanApprovalQuestion() async throws {
        let controller = makeController(currentModeId: "plan")
        controller.pendingPlanApproval = true

        let request = try #require(controller.activeQuestion)
        let question = try #require(request.questions.first)

        #expect(request.questionId == "codex-plan-approval")
        #expect(question.id == QuestionRequest.exitPlanModeId)
        #expect(
            question.options.map(\.label) == [
                QuestionRequest.implementPlanLabel,
                QuestionRequest.keepPlanningLabel,
            ])

        await controller.cancelQuestion()

        #expect(controller.activeQuestion == nil)
        #expect(!controller.pendingPlanApproval)
        #expect(controller.isPlanModeOn)
    }

    @Test("Approving a plan leaves plan mode and starts implementation")
    func approvePlan() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            modeState: Self.modeState(current: "plan")
        )
        let controller = makeController(model: model)
        controller.pendingPlanApproval = true

        await controller.answerQuestion(answers: [
            QuestionRequest.exitPlanModeId: QuestionAnswerEntry(
                answers: [QuestionRequest.implementPlanLabel]
            )
        ])

        #expect(!controller.pendingPlanApproval)
        #expect(!controller.isPlanModeOn)
        #expect(model.modeState?.currentModeId == "build")
        #expect(client.promptedTexts == ["Implement the plan."])
    }

    private static func modeState(current: String = "build") -> SessionModeState {
        SessionModeState(
            currentModeId: current,
            availableModes: [
                SessionMode(id: "build", name: "Build", canonicalId: CanonicalMode.fullAccess.rawValue),
                SessionMode(id: "plan", name: "Plan", canonicalId: CanonicalMode.plan.rawValue),
            ]
        )
    }

    private func makeController(
        model: SessionModel? = nil,
        currentModeId: String = "build"
    ) -> SessionController {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/plan-mode-tests"))
        let controller = SessionController(
            project: project,
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        controller.selectedHarnessId = "codex"
        controller.connectedHarnessId = model == nil ? nil : "codex"
        controller.modeStateByHarness["codex"] = Self.modeState(current: currentModeId)
        controller.model = model
        return controller
    }
}
