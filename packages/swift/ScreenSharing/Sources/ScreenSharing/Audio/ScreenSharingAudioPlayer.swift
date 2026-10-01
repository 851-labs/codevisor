import AVFoundation
import os

/// The viewer's side: decodes packets into the jitter buffer and plays it through the default
/// output. `setTargetDelay` lets the session keep the sound as late as the picture.
///
/// Nothing here runs on the main thread: `receive` decodes on the player's own serial queue (into
/// buffers allocated once), the engine is started, stopped and adjusted on another, and the
/// device's render thread only pulls from the real-time-safe jitter buffer. Every method may be
/// called from any thread.
public final class ScreenSharingAudioPlayer: Sendable {
  private let buffer: ScreenSharingAudioJitterBuffer
  private let decoding: Decoding
  private let output: Output

  public init(targetDelay: TimeInterval = 0.06) throws {
    guard let decoder = AVAudioConverter(from: ScreenSharingAudioFormat.opus, to: ScreenSharingAudioFormat.pcm) else {
      throw ScreenSharingError.unavailable("This Mac can't decode Opus audio.")
    }
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: Int(targetDelay * ScreenSharingAudioFormat.sampleRate))
    self.buffer = buffer
    decoding = Decoding(decoder: decoder, buffer: buffer)
    output = Output(buffer: buffer)
  }

  public var statistics: ScreenSharingAudioJitterBuffer.Statistics { buffer.statistics }

  public func setTargetDelay(_ seconds: TimeInterval) {
    buffer.targetFrames = Int(min(0.4, max(0.02, seconds)) * ScreenSharingAudioFormat.sampleRate)
  }

  /// Starts the output on the engine's queue; `failed` runs there if the device can't start.
  public func start(failed: @escaping @Sendable (any Error) -> Void = { _ in }) { output.start(failed: failed) }

  /// Output level, 0…1 (the rig's measuring viewer plays at 0).
  public func setVolume(_ volume: Float) { output.setVolume(volume) }

  /// Stops the output on the engine's queue; the caller doesn't wait for the device.
  public func stop() { output.stop() }

  /// Decodes one packet into the buffer, on the decoding queue, in the order packets arrive.
  public func receive(_ packet: ScreenSharingAudioPacket) { decoding.receive(packet) }

  /// Returns once every packet received before this call is in the jitter buffer.
  public func decoded() async { await decoding.drain() }

  /// Owns the Opus converter and its two reusable buffers; confined to `queue`.
  private final class Decoding: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codevisor.screen-sharing.audio-decode", qos: .userInteractive)
    private let decoder: AVAudioConverter
    private let buffer: ScreenSharingAudioJitterBuffer
    private let compressed = AVAudioCompressedBuffer(
      format: ScreenSharingAudioFormat.opus, packetCapacity: 1,
      maximumPacketSize: ScreenSharingAudioMessage.maximumBytes)
    private let pcm = AVAudioPCMBuffer(
      pcmFormat: ScreenSharingAudioFormat.pcm,
      frameCapacity: AVAudioFrameCount(ScreenSharingAudioFormat.framesPerPacket)
    )!

    init(decoder: AVAudioConverter, buffer: ScreenSharingAudioJitterBuffer) {
      self.decoder = decoder; self.buffer = buffer
    }

    func receive(_ packet: ScreenSharingAudioPacket) { queue.async { self.decode(packet) } }

    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }

    private func decode(_ packet: ScreenSharingAudioPacket) {
      let size = packet.payload.count
      guard size > 0, size <= Int(compressed.maximumPacketSize) else { return }
      packet.payload.withUnsafeBytes { raw in
        compressed.data.copyMemory(from: raw.baseAddress!, byteCount: size)
      }
      compressed.byteLength = UInt32(size)
      compressed.packetCount = 1
      compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
      pcm.frameLength = 0
      var supplied = false
      var error: NSError?
      let compressed = compressed
      decoder.convert(to: pcm, error: &error) { _, status in
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return compressed
      }
      guard error == nil, let channels = pcm.floatChannelData else { return }
      buffer.push(
        sequence: packet.sequence, left: channels[0], right: channels[min(1, Int(pcm.format.channelCount) - 1)],
        frames: Int(pcm.frameLength))
    }
  }

  /// Owns the engine; confined to `queue`. Starting and stopping the device can take a long
  /// while (it may wait for the audio server), so neither runs on the caller's thread.
  private final class Output: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codevisor.screen-sharing.audio-output", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let buffer: ScreenSharingAudioJitterBuffer
    private var source: AVAudioSourceNode?

    init(buffer: ScreenSharingAudioJitterBuffer) { self.buffer = buffer }

    func start(failed: @escaping @Sendable (any Error) -> Void) {
      queue.async { [self] in
        guard source == nil else { return }
        let buffer = buffer
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: ScreenSharingAudioFormat.sampleRate, channels: 2,
          interleaved: false)!
        // The render block: no allocation, no lock held beyond one bounded copy, no Swift runtime calls.
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
          let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
          guard list.count > 0, let left = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
          let right = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
          buffer.pull(frames: Int(frameCount), left: left, right: right)
          return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
          try engine.start()
          source = node
        } catch {
          engine.detach(node)
          failed(error)
        }
      }
    }

    func setVolume(_ volume: Float) { queue.async { [self] in engine.mainMixerNode.outputVolume = volume } }

    func stop() {
      queue.async { [self] in
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
      }
    }
  }
}
