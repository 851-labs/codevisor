import CodevisorCore

extension CVBrowserLinkDestination {
  var workspaceDestination: BrowserLinkDestination {
    switch self {
    case .foregroundTab: .foregroundTab
    case .window: .window
    case .splitRight: .split(.trailing)
    case .splitLeft: .split(.leading)
    case .splitAbove: .split(.top)
    case .splitBelow: .split(.bottom)
    default: .backgroundTab
    }
  }
}
