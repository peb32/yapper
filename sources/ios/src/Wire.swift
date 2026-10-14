import Foundation

// Byte layout and limits shared with sources/common/src (types.hpp, serialize.cpp, protocol.cpp).
// Everything is little endian, strings are [u16 length][utf8 bytes].

enum Limits
{
  static let protocolVersion: UInt16 = 4
  static let defaultPort: UInt16 = 5688

  static let maxUsernameBytes = 32
  static let maxServerNameBytes = 64
  static let maxChannelNameBytes = 32
  static let maxChannels = 64
  static let maxReasonBytes = 256
  static let maxPasswordBytes = 64
  static let maxChatBytes = 1024
  static let maxPayloadBytes = 64 * 1024
  static let maxUdpPacketBytes = 1400
  static let maxVideoFragments = 1000
}

enum MessageType: UInt16
{
  case serverHello = 1
  case clientHello = 2
  case serverReady = 3
  case login = 4
  case loginOk = 5
  case loginError = 6
  case userState = 7
  case userLeft = 8
  case joinChannel = 9
  case sendChat = 10
  case chat = 11
  case startShare = 12
  case stopShare = 13
  case watch = 14
  case requestKeyframe = 15
}

enum PacketKind: UInt8
{
  case ping = 0
  case voice = 1
  case video = 2
}

let headerSize = 2 + 4

struct ByteWriter
{
  private(set) var bytes: [UInt8] = []

  mutating func u8(_ value: UInt8)
  {
    bytes.append(value)
  }

  mutating func u16(_ value: UInt16)
  {
    bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
  }

  mutating func u32(_ value: UInt32)
  {
    for i in 0..<4
    {
      bytes.append(UInt8((value >> (i * 8)) & 0xFF))
    }
  }

  mutating func string(_ value: String)
  {
    let utf8 = Array(value.utf8.prefix(0xFFFF))
    u16(UInt16(utf8.count))
    bytes += utf8
  }

  mutating func raw(_ value: [UInt8])
  {
    bytes += value
  }
}

struct ByteReader
{
  private let data: [UInt8]
  private var pos = 0
  private(set) var ok = true

  init(_ data: [UInt8])
  {
    self.data = data
  }

  var atEnd: Bool
  {
    pos == data.count
  }

  private mutating func take(_ count: Int) -> ArraySlice<UInt8>
  {
    guard ok, data.count - pos >= count else
    {
      ok = false
      return []
    }
    defer { pos += count }
    return data[pos..<pos + count]
  }

  mutating func u8() -> UInt8
  {
    take(1).first ?? 0
  }

  mutating func u16() -> UInt16
  {
    take(2).reversed().reduce(0) { $0 << 8 | UInt16($1) }
  }

  mutating func u32() -> UInt32
  {
    take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
  }

  mutating func bytes(_ count: Int) -> [UInt8]
  {
    Array(take(count))
  }

  mutating func string(max: Int) -> String
  {
    let length = Int(u16())
    if length > max
    {
      ok = false
      return ""
    }
    return String(decoding: take(length), as: UTF8.self)
  }

  mutating func rest() -> [UInt8]
  {
    ok ? Array(take(data.count - pos)) : []
  }
}

// [u16 type][u32 length][payload]
func encode(_ type: MessageType, _ write: (inout ByteWriter) -> Void = { _ in }) -> [UInt8]
{
  var payload = ByteWriter()
  write(&payload)

  var out = ByteWriter()
  out.u16(type.rawValue)
  out.u32(UInt32(payload.bytes.count))
  out.raw(payload.bytes)
  return out.bytes
}

struct Message
{
  let type: UInt16
  let payload: [UInt8]
}

func parseMessage(_ bytes: [UInt8]) -> Message?
{
  var reader = ByteReader(bytes)
  let type = reader.u16()
  let length = Int(reader.u32())
  guard reader.ok, length <= Limits.maxPayloadBytes, bytes.count == headerSize + length else
  {
    return nil
  }
  return Message(type: type, payload: reader.rest())
}
