import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class PluginAccountGuideModel: Identifiable {
  public private(set) var guide: ServerPluginAccountGuide?
  public private(set) var loadError: String?
  public private(set) var isSaving = false
  public private(set) var stepIndex = 0
  public var errorMessage: String?
  public var draft: ConfigFieldDraft

  @ObservationIgnored public let spec: ServerPluginAccountSpec
  @ObservationIgnored let catalogId: String?
  @ObservationIgnored let client: any CodevisorServerClienting
  @ObservationIgnored private let serverId: String
  @ObservationIgnored private let accountId: String

  public init(
    spec: ServerPluginAccountSpec,
    serverId: String,
    catalogId: String? = nil,
    client: any CodevisorServerClienting,
    accountId: String = UUID().uuidString.lowercased()
  ) {
    self.spec = spec
    self.serverId = serverId
    self.catalogId = catalogId
    self.client = client
    self.accountId = accountId
    draft = ConfigFieldDraft(fields: spec.fields)
  }

  public var title: String { guide?.title ?? spec.guide?.title ?? spec.label }

  public var steps: [ServerPluginAccountGuide.Step] { guide?.steps ?? spec.guide?.steps ?? [] }

  public var currentStep: ServerPluginAccountGuide.Step? {
    steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
  }

  public var isFirstStep: Bool { stepIndex == 0 }

  public var isLastStep: Bool { stepIndex == steps.count - 1 }

  public var canContinue: Bool {
    guard let currentStep, !isSaving else { return false }
    if currentStep.link != nil { return guide != nil }
    if isLastStep { return draft.isComplete }
    return fields(in: currentStep).allSatisfy(isFilled)
  }

  public func load() async {
    guard guide == nil else { return }

    do {
      guide = try await client.pluginAccountGuide(serverId: serverId, accountId: accountId)
      loadError = nil
    } catch {
      loadError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  public func fields(in step: ServerPluginAccountGuide.Step) -> [ServerConfigField] {
    step.fields.compactMap { key in draft.fields.first { $0.key == key } }
  }

  public func goForward() {
    guard canContinue, !isLastStep else { return }
    errorMessage = nil
    stepIndex += 1
  }

  public func goBack() {
    guard !isFirstStep else { return }
    errorMessage = nil
    stepIndex -= 1
  }

  public func save() async -> ServerPluginAccount? {
    guard let guide, isLastStep, canContinue else { return nil }

    isSaving = true
    defer { isSaving = false }
    do {
      let saved = try await client.savePluginAccount(serverId: serverId, accountId: nil, draft: accountDraft(guide))
      errorMessage = nil
      return saved
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return nil
    }
  }

  private func accountDraft(_ guide: ServerPluginAccountGuide) -> ServerPluginAccountDraft {
    ServerPluginAccountDraft(id: guide.accountId, values: draft.submittedValues)
  }

  private func isFilled(_ field: ServerConfigField) -> Bool {
    guard let text = draft.values[field.key]?.text else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
