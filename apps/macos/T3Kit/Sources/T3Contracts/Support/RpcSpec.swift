/// Describes one Effect RPC method from `WsRpcGroup` (packages/contracts/src/rpc.ts).
///
/// Generated code declares one `RpcSpec` per method; `T3Protocol` uses it to type
/// requests, unary results, stream items and typed failures.
public struct RpcSpec<Payload: Encodable & Sendable, Success: Decodable & Sendable, Failure: Decodable & Sendable & Error>: Sendable {
  /// Wire tag, for example `"orchestration.subscribeShell"`.
  public let tag: String
  /// True when the server answers with `Chunk` messages before the final `Exit`.
  public let isStream: Bool

  public init(tag: String, isStream: Bool) {
    self.tag = tag
    self.isStream = isStream
  }
}
