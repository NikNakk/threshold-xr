import Darwin
import Foundation

/// Client state flags reported by libmonado (`mnd_client_flags`).
public struct MonadoClientFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let primaryApplication = Self(rawValue: 1 << 0)
    public static let sessionActive = Self(rawValue: 1 << 1)
    public static let sessionVisible = Self(rawValue: 1 << 2)
    public static let sessionFocused = Self(rawValue: 1 << 3)
    public static let sessionOverlay = Self(rawValue: 1 << 4)
    public static let ioActive = Self(rawValue: 1 << 5)
}

public struct MonadoClientInfo: Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var name: String
    public var flags: MonadoClientFlags
}

public struct MonadoDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var index: UInt32
    public var name: String
    public var serial: String?
    public var isHead: Bool
}

/// A snapshot read from the running service through libmonado.
public struct MonadoRuntimeSnapshot: Sendable, Equatable {
    public var apiVersion: String
    public var clients: [MonadoClientInfo]
    public var devices: [MonadoDeviceInfo]
    public var takenAt: Date

    public var headDevice: MonadoDeviceInfo? { devices.first(where: \.isHead) }
}

public enum LibMonadoError: Error, LocalizedError, Sendable, Equatable {
    case libraryUnavailable(String)
    case missingSymbol(String)
    case incompatibleAPI(String)
    case connectionFailed(Int32)
    case operationFailed(String, Int32)
    case unsafeToConnect(String)

    public var errorDescription: String? {
        switch self {
        case let .libraryUnavailable(detail): return "libmonado could not be loaded: \(detail)"
        case let .missingSymbol(name): return "libmonado is missing \(name)."
        case let .incompatibleAPI(version): return "libmonado API \(version) is not supported (expected 1.x)."
        case let .connectionFailed(code): return "Could not connect to the Monado service (libmonado result \(code))."
        case let .operationFailed(name, code): return "\(name) failed with libmonado result \(code)."
        case let .unsafeToConnect(reason): return reason
        }
    }
}

/// Read-only access to libmonado, loaded with `dlopen` so Threshold XR has
/// no link-time dependency on Monado and keeps working when it is absent.
///
/// Connecting is never done blindly: when Monado's socket is absent,
/// libmonado asks launchd to *start* the service through XPC, which would
/// claim the headset. Callers must use ``MonadoRuntimeProbe``, which only
/// connects when the service is already running and listening.
///
/// This mirrors the subset of SwiftXR's `XRMonadoRuntimeControl` that a
/// manager needs, without SwiftXR's link-time OpenXR loader dependency.
public final class LibMonado: @unchecked Sendable {
    private typealias GetVersion = @convention(c) (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void
    private typealias RootCreate = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private typealias RootDestroy = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Void
    private typealias RootUpdate = @convention(c) (OpaquePointer) -> Int32
    private typealias RootCount = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias RootClientID = @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias RootClientName = @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32
    private typealias RootClientState = @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias RootDeviceInfo = @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32
    private typealias RootDeviceString = @convention(c) (OpaquePointer, UInt32, Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32
    private typealias RootDeviceFromRole = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> Int32

    public let url: URL
    private let handle: UnsafeMutableRawPointer
    private let lock = NSLock()

    private let getVersion: GetVersion
    private let rootCreate: RootCreate
    private let rootDestroy: RootDestroy
    private let updateClients: RootUpdate
    private let clientCount: RootCount
    private let clientID: RootClientID
    private let clientName: RootClientName
    private let clientState: RootClientState
    private let deviceCount: RootCount?
    private let deviceInfo: RootDeviceInfo?
    private let deviceString: RootDeviceString?
    private let deviceFromRole: RootDeviceFromRole?

    public init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw LibMonadoError.libraryUnavailable(dlerror().map { String(cString: $0) } ?? url.path)
        }
        func required<T>(_ name: String, as _: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw LibMonadoError.missingSymbol(name) }
            return unsafeBitCast(symbol, to: T.self)
        }
        func optional<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        self.url = url
        self.handle = handle
        getVersion = try required("mnd_api_get_version", as: GetVersion.self)
        rootCreate = try required("mnd_root_create", as: RootCreate.self)
        rootDestroy = try required("mnd_root_destroy", as: RootDestroy.self)
        updateClients = try required("mnd_root_update_client_list", as: RootUpdate.self)
        clientCount = try required("mnd_root_get_number_clients", as: RootCount.self)
        clientID = try required("mnd_root_get_client_id_at_index", as: RootClientID.self)
        clientName = try required("mnd_root_get_client_name", as: RootClientName.self)
        clientState = try required("mnd_root_get_client_state", as: RootClientState.self)
        deviceCount = optional("mnd_root_get_device_count", as: RootCount.self)
        deviceInfo = optional("mnd_root_get_device_info", as: RootDeviceInfo.self)
        deviceString = optional("mnd_root_get_device_info_string", as: RootDeviceString.self)
        deviceFromRole = optional("mnd_root_get_device_from_role", as: RootDeviceFromRole.self)
        // The library stays loaded for the life of the process; unloading a
        // library that may have started threads is not worth the risk.
    }

    /// The library's API version. Does not connect to the service.
    public var apiVersion: (major: UInt32, minor: UInt32, patch: UInt32) {
        var major: UInt32 = 0, minor: UInt32 = 0, patch: UInt32 = 0
        getVersion(&major, &minor, &patch)
        return (major, minor, patch)
    }

    public var apiVersionString: String {
        let v = apiVersion
        return "\(v.major).\(v.minor).\(v.patch)"
    }

    /// Connects, reads clients and devices, and disconnects.
    /// **Only call when the service is known to be running** (see type docs).
    public func snapshot() throws -> MonadoRuntimeSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let version = apiVersion
        guard version.major == 1 else { throw LibMonadoError.incompatibleAPI(apiVersionString) }

        var root: OpaquePointer?
        let created = rootCreate(&root)
        guard created >= 0, let root else { throw LibMonadoError.connectionFailed(created) }
        defer { var r: OpaquePointer? = root; rootDestroy(&r) }

        try check(updateClients(root), "mnd_root_update_client_list")
        var count: UInt32 = 0
        try check(clientCount(root, &count), "mnd_root_get_number_clients")
        var clients: [MonadoClientInfo] = []
        for index in 0..<count {
            var id: UInt32 = 0
            guard clientID(root, index, &id) >= 0 else { continue }
            var namePointer: UnsafePointer<CChar>?
            let name = clientName(root, id, &namePointer) >= 0 ? namePointer.map { String(cString: $0) } ?? "" : ""
            var raw: UInt32 = 0
            _ = clientState(root, id, &raw)
            clients.append(MonadoClientInfo(id: id, name: name, flags: MonadoClientFlags(rawValue: raw)))
        }

        var devices: [MonadoDeviceInfo] = []
        if let deviceCount, let deviceInfo {
            var headIndex: Int32 = -1
            if let deviceFromRole { _ = deviceFromRole(root, "head", &headIndex) }
            var total: UInt32 = 0
            if deviceCount(root, &total) >= 0 {
                for index in 0..<total {
                    var id: UInt32 = 0
                    var namePointer: UnsafePointer<CChar>?
                    guard deviceInfo(root, index, &id, &namePointer) >= 0 else { continue }
                    var serialPointer: UnsafePointer<CChar>?
                    var serial: String?
                    // MND_PROPERTY_SERIAL_STRING = 1
                    if let deviceString, deviceString(root, index, 1, &serialPointer) >= 0 {
                        serial = serialPointer.map { String(cString: $0) }
                    }
                    devices.append(MonadoDeviceInfo(
                        id: id,
                        index: index,
                        name: namePointer.map { String(cString: $0) } ?? "Device \(index)",
                        serial: serial,
                        isHead: Int32(index) == headIndex
                    ))
                }
            }
        }
        return MonadoRuntimeSnapshot(apiVersion: apiVersionString, clients: clients, devices: devices, takenAt: Date())
    }

    private func check(_ result: Int32, _ name: String) throws {
        if result < 0 { throw LibMonadoError.operationFailed(name, result) }
    }
}
