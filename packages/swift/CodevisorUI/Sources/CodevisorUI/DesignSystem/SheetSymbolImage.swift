import CodevisorCore
import SwiftUI

public struct SheetSymbolImage: View {
  private let symbol: SheetSymbol

  public init(_ symbol: SheetSymbol) {
    self.symbol = symbol
  }

  public var body: some View {
    switch symbol {
    case let .system(name): Image(systemName: name)
    case let .custom(name): Image(name, bundle: .module)
    }
  }
}
