import AVFoundation

// Port of sources/client/src/audio. 48 kHz mono Opus in 20 ms frames, voice activated.

// A small jitter buffer for one person talking. Packets go in as they arrive from the network,
// and the audio thread takes one out every 20 ms, in order, after a short delay to smooth out network timing.
struct VoiceBuffer
{
  enum Result
  {
    case empty  // nothing to play
    case packet // play the packet
    case lost   // a packet is missing, let the decoder fill the gap
  }

  static let startPackets = 3 // wait for 60 ms of audio before starting
  static let maxPackets = 25  // past 500 ms, drop the oldest so the delay can't keep growing
  static let maxLost: UInt32 = 3 // a bigger gap is skipped instead of filled

  private var packets: [UInt32: [UInt8]] = [:]
  private var nextSeq: UInt32 = 0
  private var playing = false

  mutating func push(_ seq: UInt32, _ packet: [UInt8])
  {
    // Too late, that spot was already played
    if seq < nextSeq
    {
      return
    }

    packets[seq] = packet
    while packets.count > Self.maxPackets, let oldest = packets.keys.min()
    {
      packets[oldest] = nil
    }
  }

  mutating func pop(_ out: inout [UInt8]) -> Result
  {
    if !playing
    {
      guard packets.count >= Self.startPackets, let first = packets.keys.min() else
      {
        return .empty
      }
      playing = true
      nextSeq = first
    }

    // They stopped talking, or the network fell behind. Either way, buffer up again before playing more.
    guard let first = packets.keys.min() else
    {
      playing = false
      return .empty
    }

    if first > nextSeq + Self.maxLost
    {
      nextSeq = first
    }

    let seq = nextSeq
    nextSeq += 1
    guard let packet = packets.removeValue(forKey: seq) else
    {
      return .lost
    }
    out = packet
    return .packet
  }
}

final class Audio
{
  private static let frameSamples = 960 // 20 ms, what Opus expects
  private static let maxOpusBytes = 400

  // Voice activation: send while the mic is louder than this, and keep sending a bit after it gets quiet
  private static let voiceThreshold: Float = 0.01
  private static let gateHoldFrames = 15 // 300 ms

  private final class Talker
  {
    var buffer = VoiceBuffer()
    let decoder: OpaquePointer

    init?()
    {
      var error: Int32 = 0
      guard let decoder = opus_decoder_create(48000, 1, &error), error == OPUS_OK else
      {
        return nil
      }
      self.decoder = decoder
    }

    deinit
    {
      opus_decoder_destroy(decoder)
    }
  }

  private let engine = AVAudioEngine()
  private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
  private let encoder: OpaquePointer
  private let send: ([UInt8]) -> Void

  private let lock = NSLock()
  private var talkers: [UInt32: Talker] = [:]
  private var muted = false
  private var deafened = false

  private var reconfigure: NSObjectProtocol?

  // Only touched by the mic tap
  private var converter: AVAudioConverter?
  private var captured: [Float] = []
  private var gateFrames = 0

  // Only touched by the render thread
  private var mixed: [Float] = []

  init(send: @escaping ([UInt8]) -> Void) throws
  {
    self.send = send

    var error: Int32 = 0
    // shortcut: bitrate stays at Opus's default (about 51 kbit/s, not the desktop's 32), opus_encoder_ctl is variadic and Swift can't call it. Add a C shim if bandwidth matters.
    guard let encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &error), error == OPUS_OK else
    {
      throw AudioError("couldn't start the Opus encoder")
    }
    self.encoder = encoder

    do
    {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)

      // Echo cancellation, otherwise the phone speaker feeds everyone back into the mic.
      // Optional: the Simulator doesn't have it, and voice still works without it on headphones.
      let input = engine.inputNode
      try? input.setVoiceProcessingEnabled(true)

      let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, buffers in
        self?.playback(UnsafeMutableAudioBufferListPointer(buffers), Int(frameCount))
        return noErr
      }
      engine.attach(source)
      engine.connect(source, to: engine.mainMixerNode, format: format)

      try startEngine()
    }
    catch
    {
      // deinit runs from here on, it frees the encoder and stops the engine
      throw AudioError("couldn't open the microphone or speaker: \(error.localizedDescription)")
    }
  }

  deinit
  {
    if let reconfigure
    {
      NotificationCenter.default.removeObserver(reconfigure)
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    opus_encoder_destroy(encoder)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // Also runs again after a configuration change. The engine stops itself on those
  // (route change, headphones, the Simulator settling its devices) and has to be started again.
  private func startEngine() throws
  {
    let input = engine.inputNode
    input.removeTap(onBus: 0)

    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else
    {
      throw AudioError("no microphone found")
    }
    converter = AVAudioConverter(from: inputFormat, to: format)
    // Voice processing can hand over several channels, mix them down to the one Opus wants
    converter?.downmix = true
    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      self?.capture(buffer)
    }

    try engine.start()

    if reconfigure == nil
    {
      reconfigure = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        try? self?.startEngine()
      }
    }
  }

  // Called on the network queue
  func play(from: UInt32, seq: UInt32, opus: [UInt8])
  {
    lock.withLock {
      // shortcut: talkers are never removed, fine for a friends server, clean up on UserLeft if it ever matters
      if talkers[from] == nil
      {
        talkers[from] = Talker()
      }
      talkers[from]?.buffer.push(seq, opus)
    }
  }

  func setMuted(_ value: Bool)
  {
    lock.withLock { muted = value }
  }

  func setDeafened(_ value: Bool)
  {
    lock.withLock { deafened = value }
  }

  private func capture(_ buffer: AVAudioPCMBuffer)
  {
    guard let converter else
    {
      return
    }

    // The mic runs at whatever rate the hardware likes, Opus wants 48 kHz
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else
    {
      return
    }

    var given = false
    converter.convert(to: converted, error: nil) { _, status in
      if given
      {
        status.pointee = .noDataNow
        return nil
      }
      given = true
      status.pointee = .haveData
      return buffer
    }
    captured += UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))

    let silent = lock.withLock { muted || deafened }

    while captured.count >= Self.frameSamples
    {
      let loudness = sqrt(captured[..<Self.frameSamples].reduce(0) { $0 + $1 * $1 } / Float(Self.frameSamples))
      if loudness > Self.voiceThreshold
      {
        gateFrames = Self.gateHoldFrames
      }
      else if gateFrames > 0
      {
        gateFrames -= 1
      }

      if gateFrames > 0, !silent
      {
        var packet = [UInt8](repeating: 0, count: Self.maxOpusBytes)
        let size = opus_encode_float(encoder, captured, Int32(Self.frameSamples), &packet, Int32(Self.maxOpusBytes))
        if size > 0
        {
          send(Array(packet[..<Int(size)]))
        }
      }

      captured.removeFirst(Self.frameSamples)
    }
  }

  private func playback(_ buffers: UnsafeMutableAudioBufferListPointer, _ frameCount: Int)
  {
    while mixed.count < frameCount
    {
      mixFrame()
    }

    let silent = lock.withLock { deafened }
    for buffer in buffers
    {
      guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else
      {
        continue
      }
      for i in 0..<frameCount
      {
        out[i] = silent ? 0 : mixed[i]
      }
    }
    mixed.removeFirst(frameCount)
  }

  // Decodes 20 ms from everyone talking and adds it together
  private func mixFrame()
  {
    var mix = [Float](repeating: 0, count: Self.frameSamples)
    var decoded = [Float](repeating: 0, count: Self.frameSamples)
    var packet: [UInt8] = []

    lock.withLock {
      for talker in talkers.values
      {
        var samples: Int32 = 0
        switch talker.buffer.pop(&packet)
        {
        case .packet:
          samples = opus_decode_float(talker.decoder, packet, Int32(packet.count), &decoded, Int32(Self.frameSamples), 0)
        case .lost:
          samples = opus_decode_float(talker.decoder, nil, 0, &decoded, Int32(Self.frameSamples), 0)
        case .empty:
          break
        }

        for i in 0..<max(Int(samples), 0)
        {
          mix[i] += decoded[i]
        }
      }
    }

    mixed += mix.map { min(max($0, -1), 1) }
  }
}

struct AudioError: LocalizedError
{
  let errorDescription: String?

  init(_ message: String)
  {
    errorDescription = message
  }
}
