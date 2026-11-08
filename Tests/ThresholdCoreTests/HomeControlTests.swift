import Foundation
import Testing
@testable import ThresholdCore

/// Waits on the main actor, letting main-queue callbacks run.
@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

func sampleStatus(_ mode: HomeStatus.Mode = .home, foreground: String = "Home") -> HomeStatus {
    HomeStatus(mode: mode, foreground: foreground, detail: "SwiftXR Shell", runtime: "Monado",
               input: "Sense / tracked controllers", canGoHome: mode != .home, canSwitchModes: true,
               canStopApp: false, mouseCaptureEnabled: true, canRetryConnection: false)
}

@Suite("Home control channel", .serialized)
@MainActor
struct HomeControlTests {
    func socketURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "thc-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test func messagesRoundTripAsJSONLines() throws {
        let status = sampleStatus(.video, foreground: "Video")
        let data = try #require(HomeControl.encode(.status(status)))
        #expect(data.last == 0x0A)
        #expect(HomeControl.decode(data.dropLast()) == .status(status))
        #expect(HomeControl.decode(Data("not json".utf8)) == nil)
        var buffer = LineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        #expect(buffer.append(Data(":2}\n".utf8)).count == 1)
    }

    @Test func clientReceivesStatusAndServerReceivesCommands() async throws {
        let url = socketURL()
        let received = Box<[HomeCommand]>([])
        let server = HomeControlServer(socketURL: url) { received.value.append($0) }
        try server.start()
        defer { server.stop() }
        server.publish(sampleStatus())

        let statuses = Box<[HomeStatus]>([])
        let client = HomeControlClient(socketURL: url)
        client.onStatus = { statuses.value.append($0) }
        #expect(client.connect())
        // The current status arrives on connect.
        #expect(await eventually { statuses.value.last?.mode == .home })

        server.publish(sampleStatus(.desktop, foreground: "Desktop"))
        #expect(await eventually { statuses.value.last?.mode == .desktop })
        server.publish(sampleStatus(.desktop, foreground: "Desktop")) // unchanged: not resent
        try await Task.sleep(for: .milliseconds(100))
        #expect(statuses.value.count == 2)

        #expect(client.send(.video))
        #expect(client.send(.recenter))
        #expect(await eventually { received.value == [.video, .recenter] })
        client.disconnect()
    }

    @Test func clientCannotConnectWhenHomeIsNotRunning() {
        let client = HomeControlClient(socketURL: socketURL())
        #expect(!client.connect())
        #expect(!client.send(.home))
    }

    @Test func clientLearnsWhenHomeQuits() async throws {
        let url = socketURL()
        let server = HomeControlServer(socketURL: url) { _ in }
        try server.start()
        let disconnected = Box(false)
        let client = HomeControlClient(socketURL: url)
        client.onDisconnect = { disconnected.value = true }
        #expect(client.connect())
        #expect(await eventually { server.clientCount == 1 })
        server.stop()
        #expect(await eventually { disconnected.value })
        #expect(!client.isConnected)
        #expect(!FileManager.default.fileExists(atPath: url.path), "the socket file is removed")
    }

    @Test func secondServerIsRefusedButStaleSocketIsReplaced() throws {
        let url = socketURL()
        let first = HomeControlServer(socketURL: url) { _ in }
        try first.start()
        #expect(throws: HomeControlError.alreadyServed(url.path)) {
            try HomeControlServer(socketURL: url) { _ in }.start()
        }
        first.stop()
        // A file left behind by a crash does not block the next start.
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let second = HomeControlServer(socketURL: url) { _ in }
        try second.start()
        second.stop()
    }

    @Test func socketIsPrivateToTheUser() throws {
        let url = socketURL()
        let server = HomeControlServer(socketURL: url) { _ in }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
