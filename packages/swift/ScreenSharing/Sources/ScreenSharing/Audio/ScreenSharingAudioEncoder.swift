import AVFoundation

/// The host's side: PCM in, whatever format ScreenCaptureKit delivers, 20 ms Opus packets out,
/// each stamped with its first sample's capture time. Called from the capture queue; not
/// reentrant.
public final class ScreenSharingAudioEncoder: @unchecked Sendable {
  private let encoder: AVAudioConverter
  private var resampler: AVAudioConverter?
  private let chunk: AVAudioPCMBuffer
  private var chunkStartNs: Int64?
  private var sequence: UInt32 = 0
  private let onPacket: (ScreenSharingAudioPacket) -> Void

  public init(onPacket: @escaping (ScreenSharingAudioPacket) -> Void) throws {
    guard let encoder = AVAudioConverter(from: ScreenSharingAudioFormat.pcm, to: ScreenSharingAudioFormat.opus) else {
      throw ScreenSharingError.unavailable("This Mac can't encode Opus audio.")
    }
    encoder.bitRate = ScreenSharingAudioFormat.bitRate
    self.encoder = encoder
    chunk = AVAudioPCMBuffer(
      pcmFormat: ScreenSharingAudioFormat.pcm,
      frameCapacity: AVAudioFrameCount(ScreenSharingAudioFormat.framesPerPacket))!
    self.onPacket = onPacket
  }

  /// Captured PCM starting at `timestampNs`, in any PCM format (resampled to 48 kHz stereo first).
  public func append(_ buffer: AVAudioPCMBuffer, timestampNs: Int64) {
    let pcm: AVAudioPCMBuffer
    if buffer.format == ScreenSharingAudioFormat.pcm {
      pcm = buffer
    } else {
      guard let converted = resample(buffer) else { return }
      pcm = converted
    }
    var offset = 0
    var startNs = timestampNs
    let frames = Int(pcm.frameLength)
    while offset < frames {
      if chunk.frameLength == 0 { chunkStartNs = startNs }
      let room = ScreenSharingAudioFormat.framesPerPacket - Int(chunk.frameLength)
      let count = min(room, frames - offset)
      for channel in 0..<ScreenSharingAudioFormat.channels {
        let source = pcm.floatChannelData![min(channel, Int(pcm.format.channelCount) - 1)]
        let destination = chunk.floatChannelData![channel]
        (destination + Int(chunk.frameLength)).update(from: source + offset, count: count)
      }
      chunk.frameLength += AVAudioFrameCount(count)
      offset += count
      startNs += Int64(Double(count) / ScreenSharingAudioFormat.sampleRate * 1e9)
      if Int(chunk.frameLength) == ScreenSharingAudioFormat.framesPerPacket { encodeChunk() }
    }
  }

  #if os(macOS)
    /// A ScreenCaptureKit audio sample buffer.
    public func append(sampleBuffer: CMSampleBuffer) {
      guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription,
        let streamDescription = description.audioStreamBasicDescription
      else { return }
      var asbd = streamDescription
      guard let format = AVAudioFormat(streamDescription: &asbd),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
      else { return }
      buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
      guard
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
          sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples), into: buffer.mutableAudioBufferList)
          == noErr
      else { return }
      let time = CMTimeConvertScale(sampleBuffer.presentationTimeStamp, timescale: 1_000_000_000, method: .default)
      append(buffer, timestampNs: time.isNumeric ? time.value : 0)
    }
  #endif

  private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if resampler?.inputFormat != buffer.format {
      resampler = AVAudioConverter(from: buffer.format, to: ScreenSharingAudioFormat.pcm)
    }
    guard let resampler else { return nil }
    let capacity =
      AVAudioFrameCount(
        Double(buffer.frameLength) * ScreenSharingAudioFormat.sampleRate / buffer.format.sampleRate) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: ScreenSharingAudioFormat.pcm, frameCapacity: capacity) else {
      return nil
    }
    var supplied = false
    var error: NSError?
    resampler.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    return error == nil ? output : nil
  }

  private func encodeChunk() {
    defer { chunk.frameLength = 0 }
    let output = AVAudioCompressedBuffer(
      format: ScreenSharingAudioFormat.opus, packetCapacity: 1,
      maximumPacketSize: ScreenSharingAudioMessage.maximumBytes)
    var supplied = false
    var error: NSError?
    let chunk = chunk
    encoder.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return chunk
    }
    guard error == nil, output.byteLength > 0 else { return }
    let payload = Data(bytes: output.data, count: Int(output.byteLength))
    onPacket(
      ScreenSharingAudioPacket(
        sequence: sequence, timestampNs: chunkStartNs ?? 0, frames: UInt16(ScreenSharingAudioFormat.framesPerPacket),
        payload: payload))
    sequence &+= 1
  }
}
