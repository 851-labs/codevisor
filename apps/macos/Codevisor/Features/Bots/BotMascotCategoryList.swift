import CodevisorUI
import SwiftUI

struct BotMascotCategoryList: View {
  @Binding var selection: BotMascotCategory

  var body: some View {
    List(BotMascotCategory.allCases, selection: choice) { category in
      Label(category.title, systemImage: category.systemImage)
    }
    .listStyle(.sidebar)
  }

  private var choice: Binding<BotMascotCategory?> {
    Binding(get: { selection }, set: { selection = $0 ?? selection })
  }
}
