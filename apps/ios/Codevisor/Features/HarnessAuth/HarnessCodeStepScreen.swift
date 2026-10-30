import CodevisorCore
import CodevisorUI
import SwiftUI

struct HarnessCodeStepScreen: View {
  let step: HarnessCodeStep

  var body: some View {
    HarnessLoginStepScreen(
      harnessName: step.harnessName,
      step: .flow(ServerHarnessAuthFlow(id: step.id, accountId: step.id, kind: "pasteCode", url: step.url)),
      submitCode: step.submit,
      submitApiKey: { _, _, _ in nil },
      cancel: step.cancel
    )
  }
}
