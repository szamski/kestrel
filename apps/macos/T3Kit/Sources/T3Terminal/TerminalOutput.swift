import Foundation

// Port of packages/client-runtime/src/state/terminalOutput.ts. A retained, byte-capped window of
// PTY output with offsets a renderer can resume from. Offsets count UTF-16 units like the TS
// original so the same oracle cases hold; budgets count UTF-8 bytes.

public struct TerminalOutputChunk: Sendable, Hashable {
  /// UTF-16 offset within this generation and reset.
  public let startOffset: Int
  public let data: String
  public let byteLength: Int
  let length: Int  // UTF-16 length, cached: readers scan chunks on every update.

  init(startOffset: Int, data: String, byteLength: Int) {
    self.startOffset = startOffset
    self.data = data
    self.byteLength = byteLength
    self.length = data.utf16.count
  }
}

public struct TerminalOutputState: Sendable, Hashable {
  public var generation: Int
  public var chunks: [TerminalOutputChunk]
  public var retainedBytes: Int
  public var resetVersion: Int
  public var nextOffset: Int

  public static let empty = TerminalOutputState(generation: 0, chunks: [], retainedBytes: 0, resetVersion: 0, nextOffset: 0)

  public init(generation: Int, chunks: [TerminalOutputChunk], retainedBytes: Int, resetVersion: Int, nextOffset: Int) {
    self.generation = generation
    self.chunks = chunks
    self.retainedBytes = retainedBytes
    self.resetVersion = resetVersion
    self.nextOffset = nextOffset
  }

  public var text: String { chunks.map(\.data).joined() }
}

public struct TerminalOutputCursor: Sendable, Hashable {
  public var generation: Int
  public var resetVersion: Int
  public var offset: Int

  /// Forces the first `readUpdate` to resynchronize from a reset.
  public static let initial = TerminalOutputCursor(generation: -1, resetVersion: -1, offset: 0)
}

public struct TerminalOutputUpdate: Sendable, Hashable {
  public enum Kind: Sendable, Hashable { case none, reset, append }
  public let kind: Kind
  /// Full retained text for `.reset`, the unread suffix for `.append`, empty for `.none`.
  public let data: String
  public let cursor: TerminalOutputCursor
}

public enum TerminalOutput {
  public static let defaultMaxBufferBytes = 512 * 1024
  static let defaultChunkBytes = 16 * 1024
  static let maxChunks = 1_024

  /// Splits at code point boundaries; a chunk that fits whole is returned as is.
  private static func split(_ data: String, maxBytes: Int) -> [(data: String, byteLength: Int)] {
    if data.isEmpty { return [] }
    let total = data.utf8.count
    if total <= maxBytes { return [(data, total)] }
    let encoded = Array(data.utf8)
    var chunks: [(String, Int)] = []
    var offset = 0
    while offset < encoded.count {
      var end = min(offset + maxBytes, encoded.count)
      while end < encoded.count && (encoded[end] & 0xC0) == 0x80 { end -= 1 }
      // A degenerate budget smaller than one code point still has to advance.
      if end == offset {
        end = min(offset + maxBytes, encoded.count)
        while end < encoded.count && (encoded[end] & 0xC0) == 0x80 { end += 1 }
      }
      chunks.append((String(decoding: encoded[offset..<end], as: UTF8.self), end - offset))
      offset = end
    }
    return chunks
  }

  private static func trimToBytes(_ buffer: String, maxBytes: Int) -> String {
    if maxBytes <= 0 { return "" }
    let encoded = Array(buffer.utf8)
    if encoded.count <= maxBytes { return buffer }
    var start = encoded.count - maxBytes
    while start < encoded.count, (encoded[start] & 0xC0) == 0x80 { start += 1 }
    return String(decoding: encoded[start...], as: UTF8.self)
  }

  private static func splitChunks(_ data: String, firstOffset: Int, maxChunkBytes: Int) -> (chunks: [TerminalOutputChunk], nextOffset: Int, byteLength: Int) {
    var byteLength = 0
    var nextOffset = firstOffset
    let chunks = split(data, maxBytes: maxChunkBytes).map { part -> TerminalOutputChunk in
      byteLength += part.byteLength
      let chunk = TerminalOutputChunk(startOffset: nextOffset, data: part.data, byteLength: part.byteLength)
      nextOffset += chunk.length
      return chunk
    }
    return (chunks, nextOffset, byteLength)
  }

  /// Merges adjacent chunks without changing string positions, so a reader whose cursor falls
  /// inside a merged chunk can still append the unread suffix.
  private static func compact(_ chunks: [TerminalOutputChunk]) -> [TerminalOutputChunk] {
    var result: [TerminalOutputChunk] = []
    for chunk in chunks {
      if let previous = result.last,
        previous.startOffset + previous.length == chunk.startOffset,
        previous.byteLength + chunk.byteLength <= defaultChunkBytes
      {
        result[result.count - 1] = TerminalOutputChunk(
          startOffset: previous.startOffset, data: previous.data + chunk.data,
          byteLength: previous.byteLength + chunk.byteLength)
      } else {
        result.append(chunk)
      }
    }
    return result
  }

  /// Scans only the removed prefix instead of re-encoding the retained chunk.
  private static func trimStart(_ chunk: TerminalOutputChunk, bytesToDrop: Int) -> TerminalOutputChunk {
    var dropped = 0
    var utf16Offset = 0
    var index = chunk.data.unicodeScalars.startIndex
    let scalars = chunk.data.unicodeScalars
    while dropped < bytesToDrop, index < scalars.endIndex {
      let scalar = scalars[index]
      dropped += UTF8.width(scalar)
      utf16Offset += UTF16.width(scalar)
      index = scalars.index(after: index)
    }
    return TerminalOutputChunk(
      startOffset: chunk.startOffset + utf16Offset, data: String(scalars[index...]),
      byteLength: chunk.byteLength - dropped)
  }

  public static func append(_ current: TerminalOutputState, _ data: String, maxBufferBytes: Int = defaultMaxBufferBytes) -> TerminalOutputState {
    if data.isEmpty { return current }
    if maxBufferBytes <= 0 {
      return TerminalOutputState(
        generation: current.generation, chunks: [], retainedBytes: 0,
        resetVersion: current.resetVersion + 1, nextOffset: current.nextOffset + data.utf16.count)
    }
    let appended = splitChunks(data, firstOffset: current.nextOffset, maxChunkBytes: min(defaultChunkBytes, max(1, maxBufferBytes)))
    var chunks = current.chunks + appended.chunks
    var retainedBytes = current.retainedBytes + appended.byteLength
    var firstRetained = 0
    while retainedBytes > maxBufferBytes, firstRetained < chunks.count {
      let first = chunks[firstRetained]
      let bytesToDrop = retainedBytes - maxBufferBytes
      if bytesToDrop < first.byteLength {
        let trimmed = trimStart(first, bytesToDrop: bytesToDrop)
        retainedBytes -= first.byteLength - trimmed.byteLength
        if trimmed.byteLength > 0 { chunks[firstRetained] = trimmed } else { firstRetained += 1 }
        break
      }
      retainedBytes -= first.byteLength
      firstRetained += 1
    }
    var retained = firstRetained == 0 ? chunks : Array(chunks[firstRetained...])
    if retained.count > maxChunks {
      retained = compact(retained)
      let excess = retained.count - maxChunks
      if excess > 0 {
        for chunk in retained[..<excess] { retainedBytes -= chunk.byteLength }
        retained = Array(retained[excess...])
      }
    }
    return TerminalOutputState(
      generation: current.generation, chunks: retained, retainedBytes: retainedBytes,
      resetVersion: current.resetVersion, nextOffset: appended.nextOffset)
  }

  public static func reset(_ current: TerminalOutputState, _ data: String, maxBufferBytes: Int = defaultMaxBufferBytes) -> TerminalOutputState {
    let retained = trimToBytes(data, maxBytes: maxBufferBytes)
    let split = splitChunks(retained, firstOffset: 0, maxChunkBytes: min(defaultChunkBytes, max(1, maxBufferBytes)))
    return TerminalOutputState(
      generation: current.generation, chunks: split.chunks, retainedBytes: split.byteLength,
      resetVersion: current.resetVersion + 1, nextOffset: split.nextOffset)
  }

  public static func readUpdate(_ output: TerminalOutputState, cursor: TerminalOutputCursor) -> TerminalOutputUpdate {
    let next = TerminalOutputCursor(generation: output.generation, resetVersion: output.resetVersion, offset: output.nextOffset)
    if cursor.generation != output.generation || cursor.resetVersion != output.resetVersion
      || cursor.offset < (output.chunks.first?.startOffset ?? output.nextOffset)
    {
      return TerminalOutputUpdate(kind: .reset, data: output.text, cursor: next)
    }
    let unread = output.chunks.filter { $0.startOffset + $0.length > cursor.offset }
    if unread.isEmpty { return TerminalOutputUpdate(kind: .none, data: "", cursor: next) }
    let data = unread.map { chunk -> String in
      let skip = max(0, cursor.offset - chunk.startOffset)
      return skip == 0 ? chunk.data : String(decoding: Array(chunk.data.utf16.dropFirst(skip)), as: UTF16.self)
    }.joined()
    return TerminalOutputUpdate(kind: .append, data: data, cursor: next)
  }
}
