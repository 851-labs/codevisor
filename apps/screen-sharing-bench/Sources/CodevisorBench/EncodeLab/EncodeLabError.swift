enum EncodeLabError: Error, CustomStringConvertible {
  case encoder(String, Int32)
  case property(String, Int32)
  case transfer(String, Int32)
  case decoder(String, Int32)
  case missingPreset(String, [String])

  var description: String {
    switch self {
    case .encoder(let step, let status): "encoder \(step) failed: \(status)"
    case .property(let key, let status): "encoder property \(key) failed: \(status)"
    case .transfer(let step, let status): "pixel transfer \(step) failed: \(status)"
    case .decoder(let step, let status): "decoder \(step) failed: \(status)"
    case .missingPreset(let preset, let available): "no preset \(preset); the encoder has \(available)"
    }
  }
}
