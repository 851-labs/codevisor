import AVFoundation

public enum ScreenSharingAudioFormat {
  public static let sampleRate = 48_000.0
  public static let channels = 2
  public static let framesPerPacket = 960
  public static let bitRate = 128_000

  public static let pcm = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels),
    interleaved: false)!

  public static let opus: AVAudioFormat = {
    var description = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
      mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 0, mReserved: 0)
    return AVAudioFormat(streamDescription: &description)!
  }()
}
