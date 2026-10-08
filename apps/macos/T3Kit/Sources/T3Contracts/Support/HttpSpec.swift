/// Describes one endpoint of `EnvironmentHttpApi` (packages/contracts/src/environmentHttp.ts).
///
/// `Params` fill `:name` path segments, `Query` is the URL query string (both are
/// string-valued on the wire), `Body` is the request body encoded per `bodyContentType`,
/// and `Failure` decodes the tagged error body; `errorStatuses` maps error tag to HTTP status.
public struct HttpSpec<
  Params: Encodable & Sendable,
  Query: Encodable & Sendable,
  Body: Encodable & Sendable,
  Success: Decodable & Sendable,
  Failure: Decodable & Sendable & Error
>: Sendable {
  public let group: String
  public let name: String
  public let method: String
  public let path: String
  /// `application/json`, `application/x-www-form-urlencoded`, or nil when there is no body.
  public let bodyContentType: String?
  public let errorStatuses: [String: Int]

  public init(group: String, name: String, method: String, path: String, bodyContentType: String?, errorStatuses: [String: Int]) {
    self.group = group
    self.name = name
    self.method = method
    self.path = path
    self.bodyContentType = bodyContentType
    self.errorStatuses = errorStatuses
  }
}
