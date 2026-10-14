import Foundation
import Network

// Port of sources/client/src/net/connection.cpp. All state lives on one serial queue.

struct ChannelInfo: Identifiable, Hashable
{
  let id: UInt32
  let name: String
}

struct User: Identifiable, Hashable
{
  let id: UInt32
  var name: String
  var channel: UInt32
  var sharing: Bool
}

struct ChatLine: Identifiable
{
  let id = UUID()
  let from: String
  let text: String
}

enum ConnectionState
{
  case connecting
  case loggedIn
  case refused      // the server said no, see error
  case disconnected // couldn't connect, or the connection dropped
}

struct ConnectionStatus
{
  var state = ConnectionState.connecting
  var sessionId: UInt32 = 0
  var serverName = ""
  var channels: [ChannelInfo] = []
  var users: [User] = []
  var chat: [ChatLine] = [] // only the current channel, cleared when you switch
  var error = ""
}

final class Connection
{
  private static let maxChatLines = 200
  private static let pingInterval = 5.0

  // Set before start(). onStatus runs on the main queue, onVoice on the network queue.
  var onStatus: ((ConnectionStatus) -> Void)?
  var onVoice: ((UInt32, UInt32, [UInt8]) -> Void)?

  private let queue = DispatchQueue(label: "yapper.network")
  private let host: String
  private let port: UInt16
  private let username: String
  private let password: String

  // Only touched on queue
  private var tcp: NWConnection?
  private var udp: NWConnection?
  private var ping: DispatchSourceTimer?
  private let sender = StreamSender()
  private let receiver = StreamReceiver()
  private var keys: Crypto.SessionKeys?
  private var sessionId: UInt32 = 0
  private var lastSentSeq = [UInt32](repeating: 0, count: 3)
  private var assemblers: [UInt32: FrameAssembler] = [:]
  private var viewer: ScreenViewer?
  private var loggedIn = false
  private var finished = false
  private var status = ConnectionStatus()

  // Read by the UI every frame to show who is talking
  private let voiceLock = NSLock()
  private var lastVoice: [UInt32: Date] = [:]

  init(host: String, port: UInt16, username: String, password: String)
  {
    self.host = host
    self.port = port
    self.username = username
    self.password = password
  }

  func start()
  {
    queue.async { [self] in
      guard Crypto.start() else
      {
        return end(.disconnected, "libsodium failed to start")
      }

      let tcp = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
      self.tcp = tcp
      tcp.stateUpdateHandler = { [weak self] state in
        switch state
        {
        case .ready:
          self?.readFrame { self?.handleServerHello($0) }
        case .waiting(let error), .failed(let error):
          self?.end(.disconnected, "Couldn't reach the server: \(error.localizedDescription)")
        default:
          break
        }
      }
      tcp.start(queue: queue)
    }
  }

  // Safe to call from any thread
  func stop()
  {
    queue.async { [self] in
      finished = true
      teardown()
    }
  }

  func lastVoiceTime(_ id: UInt32) -> Date?
  {
    voiceLock.withLock { lastVoice[id] }
  }

  // Safe to call from any thread. Ignored until logged in.
  func switchChannel(_ channel: UInt32)
  {
    sendWhenLoggedIn(encode(.joinChannel) { $0.u32(channel) })
  }

  func sendChat(_ text: String)
  {
    guard !text.isEmpty, text.utf8.count <= Limits.maxChatBytes else
    {
      return
    }
    sendWhenLoggedIn(encode(.sendChat) { $0.string(text) })
  }

  func sendVoice(_ opus: [UInt8])
  {
    queue.async { [self] in
      guard loggedIn else
      {
        return
      }
      sendPacket(.voice, opus)
      voiceLock.withLock { lastVoice[sessionId] = Date() }
    }
  }

  // Starts receiving the sharer's screen into a new viewer. 0 stops watching.
  func watch(_ sharer: UInt32) -> ScreenViewer?
  {
    let viewer = sharer == 0 ? nil : ScreenViewer { [weak self] in self?.sendWhenLoggedIn(encode(.requestKeyframe)) }
    queue.async { [self] in
      self.viewer = viewer
    }
    sendWhenLoggedIn(encode(.watch) { $0.u32(sharer) })
    return viewer
  }

  private func sendWhenLoggedIn(_ message: [UInt8])
  {
    queue.async { [self] in
      if loggedIn
      {
        sendFrame(sender.seal(message))
      }
    }
  }

  // MARK: Handshake and login

  private func handleServerHello(_ frame: [UInt8])
  {
    guard let message = parseMessage(frame) else
    {
      return end(.disconnected, "bad handshake message")
    }

    // Check the version before the rest, a different version may use a different layout
    var reader = ByteReader(message.payload)
    let version = reader.u16()
    guard message.type == MessageType.serverHello.rawValue, version == Limits.protocolVersion else
    {
      return end(.refused, "The server runs Yapper protocol \(version), you have \(Limits.protocolVersion). Both need the same version.")
    }

    let identityKey = reader.bytes(32)
    let exchangeKey = reader.bytes(32)
    let signature = reader.bytes(64)
    guard reader.ok, reader.atEnd, Crypto.verify(signature: signature, message: exchangeKey, publicKey: identityKey) else
    {
      return end(.disconnected, "server sent a bad signature")
    }

    guard let exchange = Crypto.clientSessionKeys(serverKey: exchangeKey) else
    {
      return end(.disconnected, "server sent a bad key")
    }
    let (publicKey, keys) = exchange
    self.keys = keys

    let streamHeader = sender.start(key: keys.streamTx)
    sendFrame(encode(.clientHello) {
      $0.raw(publicKey)
      $0.raw(streamHeader)
    })

    readFrame { [self] frame in
      guard let ready = parseMessage(frame), ready.type == MessageType.serverReady.rawValue, ready.payload.count == Crypto.streamHeaderBytes,
            receiver.start(key: keys.streamRx, header: ready.payload) else
      {
        return end(.disconnected, "handshake failed")
      }

      if let refusal = checkServerKey(identityKey)
      {
        return end(.refused, refusal)
      }

      sendFrame(sender.seal(encode(.login) {
        $0.string(username)
        $0.string(password)
      }))
      readMessage { self.handleLoginReply($0) }
    }
  }

  private func handleLoginReply(_ message: Message)
  {
    var reader = ByteReader(message.payload)

    if message.type == MessageType.loginError.rawValue
    {
      let reason = reader.string(max: Limits.maxReasonBytes)
      return end(.refused, reader.ok ? reason : "The server refused the login.")
    }

    guard message.type == MessageType.loginOk.rawValue else
    {
      return end(.disconnected, "unexpected reply to Login")
    }

    sessionId = reader.u32()
    let serverName = reader.string(max: Limits.maxServerNameBytes)
    let count = Int(reader.u16())
    var channels: [ChannelInfo] = []
    for _ in 0..<min(count, Limits.maxChannels) where reader.ok
    {
      channels.append(ChannelInfo(id: reader.u32(), name: reader.string(max: Limits.maxChannelNameBytes)))
    }
    guard reader.ok, reader.atEnd, count <= Limits.maxChannels else
    {
      return end(.disconnected, "unexpected reply to Login")
    }

    loggedIn = true
    status.state = .loggedIn
    status.sessionId = sessionId
    status.serverName = serverName
    status.channels = channels
    publish()

    startUdp()
    listen()
  }

  private func listen()
  {
    readMessage { [self] message in
      handleMessage(message)
      listen()
    }
  }

  private func handleMessage(_ message: Message)
  {
    var reader = ByteReader(message.payload)

    switch MessageType(rawValue: message.type)
    {
    case .userState:
      let user = User(id: reader.u32(), name: reader.string(max: Limits.maxUsernameBytes), channel: reader.u32(), sharing: reader.u8() != 0)
      guard reader.ok, reader.atEnd else
      {
        return
      }

      if let index = status.users.firstIndex(where: { $0.id == user.id })
      {
        if user.id == sessionId, status.users[index].channel != user.channel
        {
          status.chat.removeAll()
        }
        status.users[index] = user
      }
      else
      {
        status.users.append(user)
      }

    case .userLeft:
      let id = reader.u32()
      guard reader.ok, reader.atEnd else
      {
        return
      }
      status.users.removeAll { $0.id == id }

    case .chat:
      let line = ChatLine(from: reader.string(max: Limits.maxUsernameBytes), text: reader.string(max: Limits.maxChatBytes))
      guard reader.ok, reader.atEnd else
      {
        return
      }
      status.chat.append(line)
      if status.chat.count > Self.maxChatLines
      {
        status.chat.removeFirst()
      }

    default:
      // RequestKeyframe only matters to sharers, and this client doesn't share
      return
    }

    publish()
  }

  // MARK: UDP

  private func startUdp()
  {
    // Voice and video go over UDP to the same address and port as TCP
    let endpoint = tcp?.currentPath?.remoteEndpoint ?? .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    let udp = NWConnection(to: endpoint, using: .udp)
    self.udp = udp
    udp.start(queue: queue)
    receivePacket()

    // Keeps the NAT mapping open and tells the server our address
    let ping = DispatchSource.makeTimerSource(queue: queue)
    ping.schedule(deadline: .now(), repeating: Self.pingInterval)
    ping.setEventHandler { [weak self] in self?.sendPacket(.ping, []) }
    ping.resume()
    self.ping = ping
  }

  private func receivePacket()
  {
    udp?.receiveMessage { [weak self] data, _, _, error in
      guard let self, let keys else
      {
        return
      }
      if let data, let plain = Crypto.openPacket(key: keys.packetRx, packet: [UInt8](data))
      {
        handlePacket(plain)
      }
      if error == nil
      {
        receivePacket()
      }
    }
  }

  // [u8 kind][u32 fromSessionId][u32 seq][data...]
  private func handlePacket(_ plain: [UInt8])
  {
    var reader = ByteReader(plain)
    let kind = PacketKind(rawValue: reader.u8())
    let from = reader.u32()
    let seq = reader.u32()
    let data = reader.rest()
    guard reader.ok, !data.isEmpty else
    {
      return
    }

    if kind == .voice
    {
      voiceLock.withLock { lastVoice[from] = Date() }
      onVoice?(from, seq, data)
    }
    else if kind == .video
    {
      // [u32 frameId][u16 fragmentIndex][u16 fragmentCount][u8 keyframe][bytes...]
      var fragment = ByteReader(data)
      let frameId = fragment.u32()
      let index = fragment.u16()
      let count = fragment.u16()
      let keyframe = fragment.u8() != 0
      let bytes = fragment.rest()
      guard fragment.ok else
      {
        return
      }

      if let frame = assemblers[from, default: FrameAssembler()].add(frameId: frameId, index: index, count: count, keyframe: keyframe, data: bytes)
      {
        viewer?.push(frame)
      }
    }
  }

  // [u32 sessionId][sealed: u8 kind, u32 seq, data...]
  private func sendPacket(_ kind: PacketKind, _ data: [UInt8])
  {
    guard let udp, let keys else
    {
      return
    }

    let index = Int(kind.rawValue)
    lastSentSeq[index] &+= 1

    var body = ByteWriter()
    body.u8(kind.rawValue)
    body.u32(lastSentSeq[index])
    body.raw(data)

    var packet = ByteWriter()
    packet.u32(sessionId)
    packet.raw(Crypto.sealPacket(key: keys.packetTx, plain: body.bytes))
    udp.send(content: Data(packet.bytes), completion: .idempotent)
  }

  // MARK: TCP framing, every frame is [u32 length][bytes]

  private func sendFrame(_ bytes: [UInt8])
  {
    var frame = ByteWriter()
    frame.u32(UInt32(bytes.count))
    frame.raw(bytes)
    tcp?.send(content: Data(frame.bytes), completion: .contentProcessed { [weak self] error in
      if error != nil
      {
        self?.end(.disconnected, "Lost the connection to the server.")
      }
    })
  }

  private func readExactly(_ count: Int, _ done: @escaping ([UInt8]) -> Void)
  {
    tcp?.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, _ in
      guard let data, data.count == count else
      {
        self?.end(.disconnected, "Lost the connection to the server.")
        return
      }
      done([UInt8](data))
    }
  }

  private func readFrame(_ done: @escaping ([UInt8]) -> Void)
  {
    let maxFrameBytes = headerSize + Limits.maxPayloadBytes + Crypto.streamOverhead

    readExactly(4) { [self] lengthBytes in
      var reader = ByteReader(lengthBytes)
      let length = Int(reader.u32())
      guard length > 0, length <= maxFrameBytes else
      {
        return end(.disconnected, "frame too big")
      }
      readExactly(length, done)
    }
  }

  private func readMessage(_ done: @escaping (Message) -> Void)
  {
    readFrame { [self] frame in
      guard let plain = receiver.open(frame) else
      {
        return end(.disconnected, "message failed to decrypt")
      }
      guard let message = parseMessage(plain) else
      {
        return end(.disconnected, "bad message")
      }
      done(message)
    }
  }

  // MARK: Ending

  private func end(_ state: ConnectionState, _ error: String)
  {
    guard !finished else
    {
      return
    }
    finished = true
    status.state = state
    status.error = error
    publish()
    teardown()
  }

  private func teardown()
  {
    loggedIn = false
    viewer = nil
    ping?.cancel()
    ping = nil
    tcp?.cancel()
    tcp = nil
    udp?.cancel()
    udp = nil
  }

  private func publish()
  {
    let snapshot = status
    DispatchQueue.main.async { [weak self] in
      self?.onStatus?(snapshot)
    }
  }

  // Trust on first use: remember each server's key, refuse if it ever changes
  private func checkServerKey(_ key: [UInt8]) -> String?
  {
    let server = "\(host):\(port)"
    let hex = key.map { String(format: "%02x", $0) }.joined()
    var known = UserDefaults.standard.dictionary(forKey: "knownServers") as? [String: String] ?? [:]

    if let saved = known[server]
    {
      return saved == hex ? nil : "The server's identity key changed since you last connected. Someone may be intercepting the connection. If the server owner reset the key on purpose, delete and reinstall the app to forget it."
    }

    known[server] = hex
    UserDefaults.standard.set(known, forKey: "knownServers")
    return nil
  }
}
