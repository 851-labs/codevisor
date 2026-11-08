import StreamMarkdown
import SwiftUI
import UIKit

struct QuestionCardText: View {
  let text: String
  let style: UIFont.TextStyle
  var color: UIColor = .label

  var body: some View {
    SelectableTextView(attributedText: attributedText, fillsWidth: true)
  }

  private var attributedText: NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .font: UIFont.preferredFont(forTextStyle: style),
        .foregroundColor: color,
      ]
    )
  }
}
