import AVFoundation
import Observation

// What the desktop client's Client class does, minus ImGui. Only touched on the main thread.
@Observable
final class AppModel
{
  // Shows "talking" for this long after the last voice packet
  private static let talkingTime = 0.3

  var address = UserDefaults.standard.string(forKey: "address") ?? ""
  var username = UserDefaults.standard.string(forKey: "username") ?? ""
  var password = ""

  private(set) var status: ConnectionStatus?
  private(set) var formError = ""
  private(set) var audioError = ""
  private(set) var watching: UInt32 = 0
  private(set) var viewer: ScreenViewer?

  var muted = false
  {
    didSet { audio?.setMuted(muted) }
  }

  var deafened = false
  {
    didSet { audio?.setDeafened(deafened) }
  }

  @ObservationIgnored private var connection: Connection?
  @ObservationIgnored private var audio: Audio?

  var loggedIn: Bool
  {
    status?.state == .loggedIn
  }

  var connecting: Bool
  {
    status?.state == .connecting
  }

  var myChannel: UInt32?
  {
    status.flatMap { status in status.users.first { $0.id == status.sessionId }?.channel }
  }

  var errorText: String
  {
    if !formError.isEmpty
    {
      return formError
    }
    if let status, status.state == .refused || status.state == .disconnected
    {
      return status.error
    }
    return ""
  }

  func connect()
  {
    formError = ""

    // "host" or "host:port". shortcut: IPv6 addresses aren't supported, add [::1]:port parsing if needed.
    var host = address.trimmingCharacters(in: .whitespaces)
    var port = Limits.defaultPort
    if let colon = host.lastIndex(of: ":")
    {
      guard let parsed = UInt16(host[host.index(after: colon)...]), parsed > 0 else
      {
        formError = "The port must be a number from 1 to 65535."
        return
      }
      port = parsed
      host = String(host[..<colon])
    }

    if host.isEmpty
    {
      formError = "Enter the server address."
    }
    else if username.isEmpty || username.utf8.count > Limits.maxUsernameBytes
    {
      formError = "Your name must be 1 to 32 characters."
    }
    else if password.utf8.count > Limits.maxPasswordBytes
    {
      formError = "The password can be at most 64 characters."
    }
    if !formError.isEmpty
    {
      return
    }

    UserDefaults.standard.set(address, forKey: "address")
    UserDefaults.standard.set(username, forKey: "username")

    disconnect()

    let connection = Connection(host: host, port: port, username: username, password: password)
    connection.onStatus = { [weak self] in self?.update($0) }

    audioError = AVAudioApplication.shared.recordPermission == .denied ? "Microphone access is off, others can't hear you. Turn it on in Settings > Yapper." : ""
    do
    {
      let audio = try Audio { [weak connection] in connection?.sendVoice($0) }
      audio.setMuted(muted)
      audio.setDeafened(deafened)
      connection.onVoice = { audio.play(from: $0, seq: $1, opus: $2) }
      self.audio = audio
    }
    catch
    {
      audioError = error.localizedDescription
    }

    self.connection = connection
    status = ConnectionStatus()
    connection.start()
  }

  // Keeps the chat on screen until the next connect, drops everything live
  func disconnect()
  {
    connection?.stop()
    connection = nil
    audio = nil
    viewer = nil
    watching = 0
    if status?.state == .connecting || status?.state == .loggedIn
    {
      status = nil
    }
  }

  func join(_ channel: UInt32)
  {
    if channel != myChannel
    {
      connection?.switchChannel(channel)
    }
  }

  func sendChat(_ text: String)
  {
    connection?.sendChat(text)
  }

  func isTalking(_ id: UInt32) -> Bool
  {
    guard let last = connection?.lastVoiceTime(id) else
    {
      return false
    }
    return Date().timeIntervalSince(last) < Self.talkingTime
  }

  func startWatching(_ sharer: UInt32)
  {
    viewer = connection?.watch(sharer)
    watching = viewer == nil ? 0 : sharer
  }

  func stopWatching()
  {
    if watching != 0
    {
      _ = connection?.watch(0)
    }
    viewer = nil
    watching = 0
  }

  private func update(_ status: ConnectionStatus)
  {
    // A late update from a connection we already dropped
    guard self.status != nil, connection != nil else
    {
      return
    }
    self.status = status

    if status.state == .refused || status.state == .disconnected
    {
      // Frees the mic, so iOS stops showing it in use
      connection = nil
      audio = nil
      viewer = nil
      watching = 0
      return
    }

    // Stop watching once they stop sharing, leave, or aren't in your channel anymore
    if watching != 0
    {
      let sharer = status.users.first { $0.id == watching }
      if sharer == nil || sharer?.sharing == false || sharer?.channel != myChannel
      {
        stopWatching()
      }
    }
  }
}
