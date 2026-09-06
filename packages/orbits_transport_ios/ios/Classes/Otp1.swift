import Foundation

enum Otp1 {
  static let magic: UInt32 = 0x4F545031
  static let version: UInt8 = 1
  static let request: UInt8 = 1
  static let response: UInt8 = 2
  static let event: UInt8 = 3
  static let maxPayload = 256 * 1024

  static func encode(type: UInt8, body: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: body, options: [])
    if payload.count > maxPayload {
      throw HostError.worklet("IPC_FRAME")
    }
    var header = Data(count: 10)
    header.replaceSubrange(0..<4, with: bigEndian(magic))
    header[4] = version
    header[5] = type
    header.replaceSubrange(6..<10, with: bigEndian(UInt32(payload.count)))
    var out = Data()
    out.append(header)
    out.append(payload)
    return out
  }

  private static func bigEndian(_ value: UInt32) -> Data {
    var be = value.bigEndian
    return Data(bytes: &be, count: 4)
  }
}

final class Otp1Decoder {
  private var buffer = Data()

  func reset() {
    buffer.removeAll()
  }

  func bufferedBytes() -> Int {
    return buffer.count
  }

  func add(_ chunk: Data) throws -> [Otp1Message] {
    if !chunk.isEmpty {
      buffer.append(chunk)
    }
    var out: [Otp1Message] = []
    var offset = 0
    do {
      while offset + 10 <= buffer.count {
        let magic = readUInt32(buffer, offset)
        if magic != Otp1.magic {
          reset()
          throw HostError.worklet("bad IPC magic")
        }
        let version = buffer[offset + 4]
        if version != Otp1.version {
          reset()
          throw HostError.worklet("unsupported IPC version")
        }
        let type = buffer[offset + 5]
        let len = Int(readUInt32(buffer, offset + 6))
        if len < 0 || len > Otp1.maxPayload {
          reset()
          throw HostError.worklet("IPC_FRAME")
        }
        if offset + 10 + len > buffer.count { break }
        let payload = buffer.subdata(in: (offset + 10)..<(offset + 10 + len))
        let json: Any
        do {
          json = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
          reset()
          throw HostError.worklet("malformed JSON payload")
        }
        guard let body = json as? [String: Any] else {
          reset()
          throw HostError.worklet("IPC payload must be a JSON object")
        }
        out.append(Otp1Message(type: type, body: body))
        offset += 10 + len
      }
      if offset > 0 {
        buffer.removeSubrange(0..<offset)
      }
      return out
    } catch {
      reset()
      throw error
    }
  }
}

struct Otp1Message {
  let type: UInt8
  let body: [String: Any]
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
  let slice = data.subdata(in: offset..<(offset + 4))
  var value: UInt32 = 0
  _ = withUnsafeMutableBytes(of: &value) { dest in
    slice.copyBytes(to: dest.bindMemory(to: UInt8.self))
  }
  return UInt32(bigEndian: value)
}
