import ACPKit
import CodevisorCore
import SwiftUI

struct QuestionSheetPresentation: ViewModifier {
  let controller: SessionController

  func body(content: Content) -> some View {
    content.sheet(isPresented: isPresented) {
      if let request = presentedRequest {
        QuestionSheet(controller: controller, request: request)
      }
    }
  }

  private var presentedRequest: QuestionRequest? {
    guard let request = controller.transcriptQuestion, request.questionId == controller.presentedQuestionId else {
      return nil
    }
    return request
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { presentedRequest != nil },
      set: { if !$0 { controller.presentedQuestionId = nil } }
    )
  }
}
