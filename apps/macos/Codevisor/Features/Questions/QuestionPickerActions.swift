import ACPKit

struct QuestionPickerActions {
  let submit: () -> Void
  let dismiss: () -> Void
  let answerDirectly: (QuestionSpec, String) -> Void
}
