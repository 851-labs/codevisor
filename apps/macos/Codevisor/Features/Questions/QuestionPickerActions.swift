import ACPKit

struct QuestionPickerActions {
  let submit: () -> Void
  let skip: () -> Void
  let answerDirectly: (QuestionSpec, String) -> Void
}
