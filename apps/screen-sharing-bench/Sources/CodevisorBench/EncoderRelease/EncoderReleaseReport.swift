struct EncoderReleaseStep: Encodable {
  let label: String
  let count: EncoderReleaseVTCount
}

struct EncoderReleaseReport: Encodable {
  let steps: [EncoderReleaseStep]
}
