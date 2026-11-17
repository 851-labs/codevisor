@propertyWrapper
struct SidebarSelectionRef {
  private let owner: any SidebarSelectionOwner

  init(_ owner: any SidebarSelectionOwner) {
    self.owner = owner
  }

  static func constant(_ selection: SidebarSelection?) -> SidebarSelectionRef {
    SidebarSelectionRef(ConstantSidebarSelection(selection))
  }

  var wrappedValue: SidebarSelection? {
    get { owner.selection }
    nonmutating set { owner.selection = newValue }
  }

  var projectedValue: SidebarSelectionRef { self }
}
