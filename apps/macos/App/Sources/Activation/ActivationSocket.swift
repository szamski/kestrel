import Darwin
import Foundation
import T3ClientRuntime

/// The local Unix socket `t3 app <path>` talks to (apps/desktop/src/app/DesktopAppActivation.ts): one newline-delimited JSON request per
/// connection, one JSON line back. The CLI resolves the same address from the same state directory (`DesktopAppActivation.controlAddress`),
/// so it reaches this app the way it reaches the Electron one.
///
/// As on desktop, two apps can share a state directory and the newest takes the path over: the socket is bound under a staging name and
/// renamed onto the address, `stop` unlinks the address only while it is still this socket's, and a directory watcher binds again when
/// the address disappears (the other app quit).
final class ActivationSocket: @unchecked Sendable {
  /// Answers one request with a response line. Never throws: a failure is a failure response.
  typealias Handler = @Sendable (DesktopAppActivation.Request) async -> Data

  private let directory: String
  private let address: String
  private let handle: Handler
  private let cancel: @Sendable (String) -> Void
  private let queue = DispatchQueue(label: "dev.szamowski.kestrel.activation-socket")

  // All below on `queue`.
  private var listener: Bound?
  private var accepting: DispatchSourceRead?
  private var watcher: DispatchSourceFileSystemObject?
  private var connections: [Int32: Connection] = [:]
  private var stopped = false

  private struct Bound {
    let fd: Int32
    let inode: UInt64
  }

  init(stateDir: String, handle: @escaping Handler, cancel: @escaping @Sendable (String) -> Void) {
    let resolved = DesktopAppActivation.controlAddress(stateDir: stateDir, tempDir: NSTemporaryDirectory(), userId: getuid())
    directory = resolved.directory
    address = resolved.address
    self.handle = handle
    self.cancel = cancel
  }

  var path: String { address }

  func start() throws {
    try queue.sync {
      try prepareDirectory()
      try bindAndListen(takeOver: true)
      watchDirectory()
    }
  }

  func stop() {
    queue.sync {
      stopped = true
      watcher?.cancel()
      watcher = nil
      connections.values.forEach { $0.close() }
      accepting?.cancel()
      accepting = nil
      // Only this socket's own file: another app may have taken the address over since.
      if let listener, inode(of: address) == listener.inode { unlink(address) }
      listener = nil
    }
  }

  // MARK: Binding

  private struct SocketError: Error, LocalizedError {
    var errorDescription: String?
  }

  /// The socket directory must be ours and private: the address is a local door into the app.
  private func prepareDirectory() throws {
    if mkdir(directory, 0o700) != 0, errno != EEXIST { throw SocketError(errorDescription: "mkdir \(directory): \(String(cString: strerror(errno)))") }
    var info = stat()
    guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw SocketError(errorDescription: "\(directory) is not a directory.") }
    guard info.st_uid == getuid() else { throw SocketError(errorDescription: "\(directory) is owned by another user.") }
    chmod(directory, 0o700)
  }

  private func inode(of path: String) -> UInt64? {
    var info = stat()
    return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
  }

  /// Binds a staging path, then moves it onto the address: `rename` takes the address over, `link` only claims it while it is free.
  private func bindAndListen(takeOver: Bool) throws {
    let staging = directory + "/" + (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() + ".tmp"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError(errorDescription: "socket: \(String(cString: strerror(errno)))") }
    var failure: String?
    var bound = false
    defer {
      if failure != nil { Darwin.close(fd) }
      if bound { unlink(staging) }
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard staging.utf8.count < capacity else { failure = "path too long"; throw SocketError(errorDescription: "The socket path is too long: \(staging)") }
    withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, staging, capacity) } }
    let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard bindResult == 0 else { failure = "bind"; throw SocketError(errorDescription: "bind \(staging): \(String(cString: strerror(errno)))") }
    bound = true
    guard listen(fd, 16) == 0 else { failure = "listen"; throw SocketError(errorDescription: "listen: \(String(cString: strerror(errno)))") }
    chmod(staging, 0o600)
    let stagedInode = inode(of: staging) ?? 0
    let moved = takeOver ? rename(staging, address) : link(staging, address)
    guard moved == 0 else {
      failure = "move"
      if !takeOver, errno == EEXIST { return }  // another app bound the address first
      throw SocketError(errorDescription: "\(address): \(String(cString: strerror(errno)))")
    }
    if !takeOver { unlink(staging) }
    bound = false  // renamed away, or unlinked just above
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptAll(on: fd) }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
    accepting?.cancel()  // the previous socket, when this one took over from it
    accepting = source
    listener = Bound(fd: fd, inode: stagedInode)
  }

  /// Binds again when the address file is gone, for example after the app that took it over quit. Never replaces one that exists.
  private func watchDirectory() {
    let fd = open(directory, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
    source.setEventHandler { [weak self] in
      guard let self, !stopped, inode(of: address) == nil else { return }
      try? bindAndListen(takeOver: false)
    }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
    watcher = source
    if inode(of: address) == nil { try? bindAndListen(takeOver: false) }
  }

  // MARK: Connections

  private func acceptAll(on listenFd: Int32) {
    while true {
      let client = accept(listenFd, nil, nil)
      if client < 0 { return }
      var noSigPipe: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
      let connection = Connection(fd: client, queue: queue, handle: handle, cancel: cancel) { [weak self] fd in self?.connections[fd] = nil }
      connections[client] = connection
      connection.start()
    }
  }

  /// One CLI connection: a request line within five seconds and 64 KB, then its response, then close.
  private final class Connection: @unchecked Sendable {
    let fd: Int32
    private let queue: DispatchQueue
    private let handle: Handler
    private let cancel: @Sendable (String) -> Void
    private let finished: (Int32) -> Void
    private var reader: DispatchSourceRead?
    private var timeout: DispatchSourceTimer?
    private var buffer = Data()
    private var handled = false
    private var responded = false
    private var requestId: String?
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, handle: @escaping Handler, cancel: @escaping @Sendable (String) -> Void, finished: @escaping (Int32) -> Void) {
      self.fd = fd
      self.queue = queue
      self.handle = handle
      self.cancel = cancel
      self.finished = finished
    }

    func start() {
      let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      reader.setEventHandler { [self] in readAvailable() }
      reader.resume()
      self.reader = reader
      let timeout = DispatchSource.makeTimerSource(queue: queue)
      timeout.schedule(deadline: .now() + DesktopAppActivation.readTimeout)
      timeout.setEventHandler { [self] in close() }
      timeout.resume()
      self.timeout = timeout
    }

    private func readAvailable() {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = read(fd, &chunk, chunk.count)
      if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
        // The CLI went away before it got its answer: nobody is waiting for the project any more.
        if handled, !responded, let requestId { cancel(requestId) }
        return close()
      }
      guard count > 0, !handled else { return }
      buffer.append(contentsOf: chunk[0..<count])
      guard let newline = buffer.firstIndex(of: 0x0A) else {
        if buffer.count > DesktopAppActivation.maxRequestBytes { handled = true; respond(DesktopAppActivation.failure(requestId: "invalid-request", .invalidRequest, "The desktop app request is too large.")) }
        return
      }
      handled = true
      timeout?.cancel()
      switch DesktopAppActivation.parse(line: buffer[buffer.startIndex..<newline]) {
      case .invalid(let id, let message): respond(DesktopAppActivation.failure(requestId: id, .invalidRequest, message))
      case .request(let request):
        requestId = request.requestId
        Task { [handle] in
          let response = await handle(request)
          self.queue.async { self.respond(response) }
        }
      }
    }

    private func respond(_ line: Data) {
      guard !closed, !responded else { return }
      responded = true
      var offset = 0
      while offset < line.count {
        let written = line[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { break }
      }
      close()
    }

    func close() {
      guard !closed else { return }
      closed = true
      timeout?.cancel()
      reader?.cancel()
      Darwin.close(fd)
      finished(fd)
    }
  }
}
