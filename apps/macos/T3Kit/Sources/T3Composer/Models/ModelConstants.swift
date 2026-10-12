import Foundation

/// Model/provider constants from `packages/contracts/src/model.ts` (not part of the generated
/// schema types). The oracle compares them against the TypeScript tables.
public enum ModelConstants {
  public static let defaultModel = "gpt-6-astra"
  public static let antigravityDefaultModel = "antigravity-default"
  /// Lets Muse pick the account's default model. Never sent to Muse.
  public static let museDefaultModel = "default"

  public static let defaultModelByProvider: [String: String] = [
    "codex": defaultModel,
    "claudeAgent": "claude-fable-5-1",
    "cursor": "auto",
    "grok": "grok-build",
    "muse": museDefaultModel,
    "acpRegistry": "default",
    // "default" defers to the user's own Pi settings.json model selection.
    "pi": "default",
    "opencode": "openai/gpt-5",
    "antigravity": antigravityDefaultModel,
  ]

  public static let slugAliasesByProvider: [String: [String: String]] = [
    "codex": [
      "gpt-5-codex": "gpt-5.4", "5.4": "gpt-5.4", "5.3": "gpt-5.3-codex", "gpt-5.3": "gpt-5.3-codex",
      "5.3-spark": "gpt-5.3-codex-spark", "gpt-5.3-spark": "gpt-5.3-codex-spark",
    ],
    "claudeAgent": [:],
    "cursor": [
      "composer": "composer-2", "composer-1.5": "composer-1.5", "composer-1": "composer-1.5",
      "opus-4.6-thinking": "claude-opus-4-6", "opus-4.6": "claude-opus-4-6",
      "sonnet-4.6-thinking": "claude-sonnet-4-6", "sonnet-4.6": "claude-sonnet-4-6",
      "opus-4.5-thinking": "claude-opus-4-5", "opus-4.5": "claude-opus-4-5",
    ],
    "opencode": [:],
  ]

  public static let providerDisplayNames: [String: String] = [
    "antigravity": "Antigravity", "codex": "Codex", "claudeAgent": "Claude", "cursor": "Cursor", "grok": "Grok",
    "muse": "Muse Code", "acpRegistry": "ACP Registry", "pi": "Pi", "opencode": "OpenCode",
  ]

  public static let maxInputChars = 120_000
  public static let maxAttachments = 100
  public static let maxImageBytes = 10 * 1024 * 1024
  public static let maxTotalImageBytes = 80 * 1024 * 1024
  public static let maxFileBytes = 50 * 1024 * 1024
  public static let supportedImageMimeTypes = ["image/gif", "image/jpeg", "image/png", "image/webp"]

  public static func isSupportedImageMimeType(_ mimeType: String) -> Bool {
    supportedImageMimeTypes.contains(mimeType.lowercased())
  }
}
