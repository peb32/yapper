// Same libsodium calls as sources/common/src/crypto.cpp, so both sides derive the same keys.

enum Crypto
{
  // crypto_secretstream_xchacha20poly1305_ABYTES / HEADERBYTES, crypto_aead_xchacha20poly1305_ietf_NPUBBYTES / ABYTES
  static let streamOverhead = 17
  static let streamHeaderBytes = 24
  static let nonceBytes = 24
  static let packetTagBytes = 16

  static func start() -> Bool
  {
    sodium_init() >= 0
  }

  static func verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool
  {
    crypto_sign_verify_detached(signature, message, UInt64(message.count), publicKey) == 0
  }

  struct SessionKeys
  {
    var streamRx: [UInt8]
    var streamTx: [UInt8]
    var packetRx: [UInt8]
    var packetTx: [UInt8]
  }

  // Returns our public exchange key and the session keys, nil if the server sent a bad key
  static func clientSessionKeys(serverKey: [UInt8]) -> (publicKey: [UInt8], keys: SessionKeys)?
  {
    var publicKey = [UInt8](repeating: 0, count: 32)
    var secretKey = [UInt8](repeating: 0, count: 32)
    crypto_kx_keypair(&publicKey, &secretKey)

    var rx = [UInt8](repeating: 0, count: 32)
    var tx = [UInt8](repeating: 0, count: 32)
    guard crypto_kx_client_session_keys(&rx, &tx, publicKey, secretKey, serverKey) == 0 else
    {
      return nil
    }

    func derive(_ id: UInt64, _ key: [UInt8]) -> [UInt8]
    {
      var out = [UInt8](repeating: 0, count: 32)
      crypto_kdf_derive_from_key(&out, 32, id, "yapperkx", key)
      return out
    }

    let keys = SessionKeys(streamRx: derive(1, rx), streamTx: derive(1, tx), packetRx: derive(2, rx), packetTx: derive(2, tx))
    return (publicKey, keys)
  }

  // UDP: [random nonce][sealed]
  static func sealPacket(key: [UInt8], plain: [UInt8]) -> [UInt8]
  {
    var nonce = [UInt8](repeating: 0, count: nonceBytes)
    randombytes_buf(&nonce, nonceBytes)

    var sealed = [UInt8](repeating: 0, count: plain.count + packetTagBytes)
    crypto_aead_xchacha20poly1305_ietf_encrypt(&sealed, nil, plain, UInt64(plain.count), nil, 0, nil, nonce, key)
    return nonce + sealed
  }

  static func openPacket(key: [UInt8], packet: [UInt8]) -> [UInt8]?
  {
    guard packet.count >= nonceBytes + packetTagBytes else
    {
      return nil
    }

    let nonce = Array(packet[..<nonceBytes])
    let sealed = Array(packet[nonceBytes...])
    var plain = [UInt8](repeating: 0, count: sealed.count - packetTagBytes)
    guard crypto_aead_xchacha20poly1305_ietf_decrypt(&plain, nil, nil, sealed, UInt64(sealed.count), nil, 0, nonce, key) == 0 else
    {
      return nil
    }
    return plain
  }
}

// TCP: an ordered stream of messages, catches dropped, reordered or replayed ones
final class StreamSender
{
  private var state = crypto_secretstream_xchacha20poly1305_state()

  func start(key: [UInt8]) -> [UInt8]
  {
    var header = [UInt8](repeating: 0, count: Crypto.streamHeaderBytes)
    crypto_secretstream_xchacha20poly1305_init_push(&state, &header, key)
    return header
  }

  func seal(_ plain: [UInt8]) -> [UInt8]
  {
    var sealed = [UInt8](repeating: 0, count: plain.count + Crypto.streamOverhead)
    crypto_secretstream_xchacha20poly1305_push(&state, &sealed, nil, plain, UInt64(plain.count), nil, 0, 0)
    return sealed
  }
}

final class StreamReceiver
{
  private var state = crypto_secretstream_xchacha20poly1305_state()

  func start(key: [UInt8], header: [UInt8]) -> Bool
  {
    crypto_secretstream_xchacha20poly1305_init_pull(&state, header, key) == 0
  }

  func open(_ sealed: [UInt8]) -> [UInt8]?
  {
    guard sealed.count >= Crypto.streamOverhead else
    {
      return nil
    }

    var plain = [UInt8](repeating: 0, count: sealed.count - Crypto.streamOverhead)
    var tag: UInt8 = 0
    guard crypto_secretstream_xchacha20poly1305_pull(&state, &plain, nil, &tag, sealed, UInt64(sealed.count), nil, 0) == 0 else
    {
      return nil
    }
    return plain
  }
}
