import CodevisorCore

struct ActiveTranscriptProjectionBinding: Equatable {
  let projection: ActiveTranscriptProjection
  let controller: SessionController

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.projection === rhs.projection && lhs.controller === rhs.controller
  }
}
