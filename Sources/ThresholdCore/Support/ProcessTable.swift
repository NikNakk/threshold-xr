import Darwin
import Foundation

/// The user's processes and their arguments, read with libproc and sysctl
/// (no `ps` or `pgrep` child processes).
public enum ProcessTable {
    public struct Entry: Sendable, Equatable {
        public var pid: Int32
        public var parent: Int32
        public var arguments: [String]

        public var name: String { arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
    }

    public static func all() -> [Entry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }.compactMap(entry)
    }

    public static func entry(_ pid: Int32) -> Entry? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Entry(pid: pid, parent: Int32(info.pbi_ppid), arguments: arguments(pid))
    }

    /// argv, from KERN_PROCARGS2 (empty for processes we may not inspect).
    public static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var out: [String] = []
        while out.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            out.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        return out
    }

    public static func isRunning(named name: String) -> Bool {
        all().contains { $0.name == name }
    }

    /// A process's descendants, children before grandchildren.
    public static func descendants(of pid: Int32, in table: [Entry] = all()) -> [Entry] {
        var out: [Entry] = []
        var frontier = [pid]
        while let next = frontier.popLast() {
            let children = table.filter { $0.parent == next && $0.pid != next }
            out += children
            frontier += children.map(\.pid)
        }
        return out
    }
}
