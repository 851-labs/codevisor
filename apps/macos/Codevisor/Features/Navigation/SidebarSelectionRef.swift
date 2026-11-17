@propertyWrapper
struct SidebarSelectionRef {
  private let read: () -> SidebarSelection?
  private let write: (SidebarSelection?) -> Void

  init(_ owner: any SidebarSelectionOwner) {
    read = { owner.selection }
    write = { owner.selection = $0 }
  }

  private init(constant selection: SidebarSelection?) {
    read = { selection }
    write = { _ in }
  }

  static func constant(_ selection: SidebarSelection?) -> SidebarSelectionRef {
    SidebarSelectionRef(constant: selection)
  }

  var wrappedValue: SidebarSelection? {
    get { read() }
    nonmutating set { write(newValue) }
  }

  var projectedValue: SidebarSelectionRef { self }
}
