import ScreenSharingBench

enum Tier2SystemLabel {
  static let legend =
    "Systems: Apple HP is Apple's Screen Sharing in High Performance mode. Codevisor, default encoder is Codevisor "
    + "with the encoder the app ships with (Apple's real-time encoder, VCP). Codevisor, fallback encoder is Codevisor "
    + "with VideoToolbox, which the app uses when the default encoder fails or the link is slow."

  static func of(_ system: BenchSystem) -> String {
    switch system {
    case .appleHP: "Apple HP"
    case .codevisor: "Codevisor, engine v1"
    case .codevisorV2: "Codevisor, fallback encoder (VideoToolbox)"
    case .codevisorV2VCP: "Codevisor, default encoder (VCP)"
    case .codevisorV2Before: "LAB: Codevisor, fallback encoder (VideoToolbox), BEFORE 851-4475"
    case .codevisorV2VCPBefore: "LAB: Codevisor, default encoder (VCP), BEFORE 851-4475"
    }
  }
}
