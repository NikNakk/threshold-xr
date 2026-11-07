import Darwin
import Foundation

/// Unix-domain sockets held by a process, read from the kernel's file table
/// with `libproc`. This is passive: unlike connecting to Monado, it does not
/// add or remove an IPC client, so it cannot start the service or trigger
/// its idle-exit timer.
public struct ProcessSocketSummary: Sendable, Equatable {
    /// Paths of listening Unix sockets.
    public var listeningPaths: [String]
    /// Number of connected (accepted) Unix-domain stream sockets. For
    /// `monado-service` this approximates the number of IPC clients.
    public var connectedCount: Int

    public init(listeningPaths: [String], connectedCount: Int) {
        self.listeningPaths = listeningPaths
        self.connectedCount = connectedCount
    }

    public func isListening(on path: String) -> Bool {
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return listeningPaths.contains { candidate in
            candidate == path || URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path == wanted
        }
    }
}

public protocol ProcessSocketInspecting: Sendable {
    func sockets(of pid: Int32) -> ProcessSocketSummary?
}

public struct LibprocSocketInspector: ProcessSocketInspecting {
    public init() {}

    public func sockets(of pid: Int32) -> ProcessSocketSummary? {
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        // Leave headroom for descriptors opened between the two calls.
        let capacity = Int(needed) / fdInfoSize + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bytes = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / fdInfoSize

        var listening: [String] = []
        var connected = 0
        for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let socket = info.psi
            guard socket.soi_family == AF_UNIX, socket.soi_kind == Int32(SOCKINFO_UN) else { continue }
            guard socket.soi_type == SOCK_STREAM else { continue }

            if socket.soi_options & Int16(SO_ACCEPTCONN) != 0 {
                var address = socket.soi_proto.pri_un.unsi_addr.ua_sun
                let path = withUnsafeBytes(of: &address.sun_path) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if !path.isEmpty { listening.append(path) }
            } else {
                connected += 1
            }
        }
        return ProcessSocketSummary(listeningPaths: listening, connectedCount: connected)
    }
}
