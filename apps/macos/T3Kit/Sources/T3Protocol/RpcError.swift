import Foundation

/// Why a session stopped being usable. Every pending request fails with
/// `RpcError.transportClosed` carrying one of these.
public enum RpcConnectionError: Error, Sendable, Equatable {
  /// `RpcSession.close()` was called.
  case closedByClient
  /// The peer or the network closed the socket.
  case closed(String)
  /// No `Pong` arrived for a whole ping interval.
  case pingTimeout
  /// The server sent a frame that is not valid RPC JSON.
  case protocolError(String)
  /// Writing a frame to the socket failed.
  case sendFailed(String)
}

/// Result of a failed RPC. `Failure` is the spec's typed domain error.
public enum RpcError<Failure: Error & Sendable>: Error, Sendable {
  /// `Exit.Failure` with a `Fail` cause: the typed error the server declared.
  case failure(Failure)
  /// A `Die` cause, a top-level `Defect`, or a response that did not match the spec.
  case defect(RawJSON)
  /// The request was interrupted (server `Interrupt` cause or local cancellation).
  case interrupted
  /// The session closed before the request completed.
  case transportClosed(RpcConnectionError)
}
