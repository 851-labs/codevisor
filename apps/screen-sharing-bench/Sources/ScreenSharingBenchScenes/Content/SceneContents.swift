import Metal

enum SceneContents {
  static func make(_ setup: BenchSceneSetup, device: any MTLDevice) throws -> any SceneContent {
    let factory = SceneTextureFactory(device: device)
    switch setup.scene {
    case .idleCursor: return try IdleCursorContent(setup, textures: factory)
    case .typing: return try TypingContent(setup, textures: factory)
    case .scroll: return try ScrollContent(setup, textures: factory)
    case .windowDrag: return try WindowDragContent(setup, textures: factory)
    case .video: return try VideoContent(setup, textures: factory)
    case .testCards: return try TestCardsContent(setup, textures: factory)
    case .input: return InputContent(setup)
    }
  }
}
