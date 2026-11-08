import Darwin
import Foundation

/// What Threshold Home reports to Threshold XR: the content of the Shell's
/// former status window, plus which actions are currently possible.
public struct HomeStatus: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case connecting, unavailable, home, video, desktop, browser, external
    }

    public var protocolVersion: Int
    public var pid: Int32
    public var mode: Mode
    /// The foreground mode or VR application, e.g. "Video" or "Open Brush".
    public var foreground: String
    public var detail: String
    public var runtime: String
    public var input: String
    public var canGoHome: Bool
    public var canSwitchModes: Bool
    public var canStopApp: Bool
    public var mouseCaptureEnabled: Bool
    public var canRetryConnection: Bool

    public init(protocolVersion: Int = HomeControl.protocolVersion, pid: Int32 = getpid(), mode: Mode,
                foreground: String, detail: String, runtime: String, input: String,
                canGoHome: Bool, canSwitchModes: Bool, canStopApp: Bool,
                mouseCaptureEnabled: Bool, canRetryConnection: Bool) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.mode = mode
        self.foreground = foreground
        self.detail = detail
        self.runtime = runtime
        self.input = input
        self.canGoHome = canGoHome
        self.canSwitchModes = canSwitchModes
        self.canStopApp = canStopApp
        self.mouseCaptureEnabled = mouseCaptureEnabled
        self.canRetryConnection = canRetryConnection
    }
}

/// Actions Threshold XR can ask Threshold Home to perform. These are the
/// Shell's former Mode and Input menu items, plus quitting.
public enum HomeCommand: String, Codable, Sendable, CaseIterable {
    case home, video, desktop, browser, recenter, stopApp, toggleMouse, retryConnection, quit
}

/// The Threshold XR ⇄ Threshold Home control channel: newline-delimited
/// JSON over a Unix socket that only the current user can open. Home is the
/// server (it owns the state); Threshold XR connects whenever it runs, so
/// either can quit and start independently.
public enum HomeControl {
    public static let protocolVersion = 1

    enum Message: Codable, Equatable {
        case status(HomeStatus)
        case command(HomeCommand)
    }

    /// `~/Library/Application Support/Threshold XR/home-control.sock`, or a
    /// per-user temporary path when that would exceed the socket path limit.
    public static func socketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let preferred = home.appending(path: "Library/Application Support/Threshold XR/home-control.sock")
        if preferred.path.utf8.count < 100 { return preferred }
        return FileManager.default.temporaryDirectory.appending(path: "threshold-home-control.sock")
    }

    static func encode(_ message: Message) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: line)
    }
}

public enum HomeControlError: Error, LocalizedError, Equatable {
    case socketPathTooLong(String)
    case alreadyServed(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path): return "The Home control socket path is too long: \(path)"
        case let .alreadyServed(path): return "Another Threshold Home is already serving \(path)."
        case let .system(call, code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

// MARK: Socket helpers

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw HomeControlError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HomeControlError.system("socket", errno) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw HomeControlError.system("connect", code)
        }
        try configure(fd)
        return fd
    }

    /// Non-blocking, no SIGPIPE, and only from this user.
    static func configure(_ fd: Int32) throws {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            throw HomeControlError.system("getpeereid", EPERM)
        }
    }

    /// Writes all bytes; false when the peer has gone or is not keeping up.
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            var spins = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && (errno == EAGAIN || errno == EINTR) && spins < 200 {
                    spins += 1
                    usleep(500)
                    continue
                }
                return false
            }
            return true
        }
    }
}

/// Splits a byte stream into newline-terminated lines.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > 1 << 20 { pending.removeAll() } // never buffer unbounded junk
        return lines
    }
}

/// One connected peer, read with a dispatch source.
final class SocketConnection: @unchecked Sendable {
    let fd: Int32
    private let source: DispatchSourceRead
    private var buffer = LineBuffer()
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, onLine: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                for line in self.buffer.append(Data(chunk[0..<count])) { onLine(line) }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                self.close()
                onClose()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    func send(_ data: Data) -> Bool { !closed && UnixSocket.write(data, to: fd) }

    func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
    }
}

// MARK: Server (Threshold Home)

/// Serves Home's status and receives commands. Commands are delivered on
/// the main queue; `publish` may be called from the main actor.
public final class HomeControlServer: @unchecked Sendable {
    public let socketURL: URL
    private let queue = DispatchQueue(label: "threshold.home-control.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [SocketConnection] = []
    private var lastStatus: HomeStatus?
    private let onCommand: @Sendable (HomeCommand) -> Void

    public init(socketURL: URL = HomeControl.socketURL(), onCommand: @escaping @Sendable (HomeCommand) -> Void) {
        self.socketURL = socketURL
        self.onCommand = onCommand
    }

    deinit { stop() }

    public func start() throws {
        let path = socketURL.path
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A live server answers; a stale file from a crash does not.
        if let fd = try? UnixSocket.connect(path) {
            close(fd)
            throw HomeControlError.alreadyServed(path)
        }
        unlink(path)
        var address = try UnixSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HomeControlError.system("socket", errno) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { let code = errno; close(fd); throw HomeControlError.system("bind", code) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let code = errno; close(fd); throw HomeControlError.system("listen", code) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Sends the status to every client if it changed, and remembers it for
    /// clients that connect later.
    public func publish(_ status: HomeStatus) {
        queue.async { [self] in
            guard status != lastStatus else { return }
            lastStatus = status
            guard let data = HomeControl.encode(.status(status)) else { return }
            clients.removeAll { client in
                if client.send(data) { return false }
                client.close()
                return true
            }
        }
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            clients.forEach { $0.close() }
            clients.removeAll()
            if listenFD >= 0 { unlink(socketURL.path) }
            listenFD = -1
        }
    }

    public var clientCount: Int { queue.sync { clients.count } }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0, (try? UnixSocket.configure(fd)) != nil else { return }
        weak var weakConnection: SocketConnection?
        let connection = SocketConnection(fd: fd, queue: queue, onLine: { [weak self] line in
            guard case let .command(command)? = HomeControl.decode(line), let self else { return }
            let handler = self.onCommand
            DispatchQueue.main.async { handler(command) }
        }, onClose: { [weak self] in
            self?.clients.removeAll { $0 === weakConnection }
        })
        weakConnection = connection
        clients.append(connection)
        if let lastStatus, let data = HomeControl.encode(.status(lastStatus)) {
            _ = connection.send(data)
        }
    }
}

// MARK: Client (Threshold XR)

/// Connects to a running Threshold Home. Status and disconnection are
/// delivered on the main queue.
public final class HomeControlClient: @unchecked Sendable {
    public let socketURL: URL
    private let queue = DispatchQueue(label: "threshold.home-control.client")
    private var connection: SocketConnection?
    public var onStatus: (@Sendable (HomeStatus) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    public init(socketURL: URL = HomeControl.socketURL()) {
        self.socketURL = socketURL
    }

    deinit { disconnect() }

    public var isConnected: Bool { queue.sync { connection != nil } }

    /// Connects if Home is serving; returns false when it is not running.
    @discardableResult
    public func connect() -> Bool {
        queue.sync {
            if connection != nil { return true }
            guard let fd = try? UnixSocket.connect(socketURL.path) else { return false }
            connection = SocketConnection(fd: fd, queue: queue, onLine: { [weak self] line in
                guard case let .status(status)? = HomeControl.decode(line), let handler = self?.onStatus else { return }
                DispatchQueue.main.async { handler(status) }
            }, onClose: { [weak self] in
                self?.connection = nil
                if let handler = self?.onDisconnect { DispatchQueue.main.async { handler() } }
            })
            return true
        }
    }

    /// Sends a command; false when not connected.
    @discardableResult
    public func send(_ command: HomeCommand) -> Bool {
        queue.sync {
            guard let connection, let data = HomeControl.encode(.command(command)) else { return false }
            return connection.send(data)
        }
    }

    public func disconnect() {
        queue.sync {
            connection?.close()
            connection = nil
        }
    }
}
