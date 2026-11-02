import CodevisorCore
import SwiftUI

struct BotMascotColorPicker: View {
  let colors: [ServerBotMascotOptions.ColorChoice]
  @Binding var selection: String

  var body: some View {
    LabeledContent("Color") {
      HStack(spacing: 6) {
        ForEach(colors) { color in
          BotMascotColorSwatch(color: color, isSelected: color.id == selection) { selection = color.id }
        }
      }
    }
  }
}
