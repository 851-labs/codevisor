import AVFoundation
import os

/// The viewer's side: decodes packets into the jitter buffer and plays it through the default
/// output. `setTargetDelay` lets the session keep the sound as late as the picture.
public final class ScreenSharingAudioPlayer: @unchecked Sendable {
  private let decoder: AVAudioConverter
  private let engine = AVAudioEngine()
  private let buffer: OSAllocatedUnfairLock<ScreenSharingAudioJitterBuffer>
  private var source: AVAudioSourceNode?

  public init(targetDelay: TimeInterval = 0.06) throws {
    guard let decoder = AVAudioConverter(from: ScreenSharingAudioFormat.opus, to: ScreenSharingAudioFormat.pcm) else {
      throw ScreenSharingError.unavailable("This Mac can't decode Opus audio.")
    }
    self.decoder = decoder
    buffer = OSAllocatedUnfairLock(
      initialState: ScreenSharingAudioJitterBuffer(
        targetFrames: Int(targetDelay * ScreenSharingAudioFormat.sampleRate)))
  }

  public var statistics: (buffered: Int, underruns: Int, lost: Int, dropped: Int) {
    buffer.withLock { ($0.bufferedFrames, $0.underruns, $0.lostPackets, $0.droppedFrames) }
  }

  public func setTargetDelay(_ seconds: TimeInterval) {
    let frames = Int(min(0.4, max(0.02, seconds)) * ScreenSharingAudioFormat.sampleRate)
    buffer.withLock { $0.targetFrames = frames }
  }

  public func start() throws {
    guard source == nil else { return }
    let buffer = buffer
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: ScreenSharingAudioFormat.sampleRate, channels: 2, interleaved: false)!
    let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
      let frames = Int(frameCount)
      let samples = buffer.withLock { $0.pull(frames: frames) }
      let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
      for (channel, audio) in list.enumerated() {
        guard let data = audio.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for index in 0..<frames { data[index] = samples[index * 2 + min(channel, 1)] }
      }
      return noErr
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try engine.start()
    source = node
  }

  /// Output level, 0…1 (the rig's measuring viewer plays at 0).
  public var volume: Float {
    get { engine.mainMixerNode.outputVolume }
    set { engine.mainMixerNode.outputVolume = newValue }
  }

  public func stop() {
    engine.stop()
    if let source { engine.detach(source) }
    source = nil
  }

  /// Decodes one packet into the buffer.
  public func receive(_ packet: ScreenSharingAudioPacket) {
    let compressed = AVAudioCompressedBuffer(
      format: ScreenSharingAudioFormat.opus, packetCapacity: 1, maximumPacketSize: max(1, packet.payload.count))
    packet.payload.withUnsafeBytes { raw in
      compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.payload.count)
    }
    compressed.byteLength = UInt32(packet.payload.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
      mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.payload.count))
    guard
      let pcm = AVAudioPCMBuffer(
        pcmFormat: ScreenSharingAudioFormat.pcm,
        frameCapacity: AVAudioFrameCount(ScreenSharingAudioFormat.framesPerPacket))
    else { return }
    var supplied = false
    var error: NSError?
    decoder.convert(to: pcm, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return compressed
    }
    guard error == nil else { return }
    let frames = Int(pcm.frameLength)
    var interleaved = [Float](repeating: 0, count: frames * 2)
    for channel in 0..<2 {
      let data = pcm.floatChannelData![channel]
      for index in 0..<frames { interleaved[index * 2 + channel] = data[index] }
    }
    let samples = interleaved
    buffer.withLock { $0.push(sequence: packet.sequence, samples: samples) }
  }
}
