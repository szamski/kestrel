import Foundation

public struct CloudAccount: Sendable, Equatable {
  /// The stable cloud user id (Clerk `user_…`); what links, tokens and cached credentials are tied to.
  public let id: String
  public let email: String?
  public let imageURL: URL?

  public init(id: String, email: String?, imageURL: URL? = nil) {
    self.id = id
    self.email = email
    self.imageURL = imageURL
  }
}

/// Sign-in providers the production T3 Clerk instance has enabled (checked against its public `/v1/environment`).
public enum CloudSignInProvider: String, CaseIterable, Sendable, Identifiable {
  case github, google, microsoft, apple
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .github: "GitHub"
    case .google: "Google"
    case .microsoft: "Microsoft"
    case .apple: "Apple"
    }
  }
}

public enum CloudSessionError: Error, Sendable, Equatable, LocalizedError {
  case signedOut
  case incomplete(String)

  public var errorDescription: String? {
    switch self {
    case .signedOut: "Sign in to your T3 account to use T3 Connect."
    case .incomplete(let message): message
    }
  }
}

/// The cloud identity boundary: what T3 Connect needs from Clerk and nothing else, so the rest is testable without it.
/// Clerk persists its own session (Keychain) and runs the system web authentication for OAuth.
@MainActor
public protocol CloudSession: AnyObject, Sendable {
  /// The signed-in account, nil when signed out.
  var account: CloudAccount? { get }
  /// Emits after sign-in, sign-out and session changes, with the account then current.
  var accountChanges: AsyncStream<CloudAccount?> { get }
  /// Loads the saved session and refreshes it with Clerk. Safe to call repeatedly.
  func refresh() async
  /// A fresh token for the relay's JWT template (never a cached one: the relay checks its age).
  func relayToken() async throws -> String
  func signIn(with provider: CloudSignInProvider) async throws
  /// Sends a one-time code to an existing account's email address.
  func startEmailCode(email: String) async throws
  func verifyEmailCode(_ code: String) async throws
  func signOut() async throws
}
