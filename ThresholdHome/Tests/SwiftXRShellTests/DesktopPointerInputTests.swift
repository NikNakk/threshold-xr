import AppKit
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Desktop controller pointer", .serialized)
@MainActor
struct DesktopPointerInputTests {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func makeInput(trusted: Bool = true, events: @escaping (CGEvent) -> Void,
                   clock: @escaping () -> TimeInterval = { 0 }) -> DesktopPointerInput {
        DesktopPointerInput(displayFrame: display, isTrusted: { trusted }, deliver: events, now: clock)
    }

    @Test func clickAndDragPostSystemWideAtDisplayPoints() throws {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        input.handle(.pointerMoved(to: SIMD2(0.6, 0.5)))
        input.handle(.pointerUp(.primary))
        #expect(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
        // Not addressed to a window: the event goes wherever the cursor is.
        #expect(events.allSatisfy { $0.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 0 })
        let first = try #require(events.first)
        #expect(abs(first.location.x - 755.5) < 0.001 && abs(first.location.y - 490.5) < 0.001)
        #expect(!input.isDown)
    }

    @Test func trackingJitterDoesNotMoveTheCursor() {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        // About 0.75 points: below the deadband, so the physical mouse keeps control.
        input.handle(.pointerMoved(to: SIMD2(0.5005, 0.5)))
        #expect(events.count == 1)
        // A real move is posted.
        input.handle(.pointerMoved(to: SIMD2(0.52, 0.5)))
        #expect(events.count == 2)
    }

    @Test func smallMovesStillDragWhileHeld() {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        input.handle(.pointerMoved(to: SIMD2(0.5005, 0.5)))
        #expect(events.last?.type == .leftMouseDragged)
    }

    @Test func secondQuickClickIsADoubleClick() {
        var events: [CGEvent] = []
        var time: TimeInterval = 10
        let input = makeInput(events: { events.append($0) }, clock: { time })
        input.handle(.pointerMoved(to: SIMD2(0.3, 0.3)))
        input.handle(.pointerDown(.primary)); input.handle(.pointerUp(.primary))
        time += 0.1
        input.handle(.pointerDown(.primary)); input.handle(.pointerUp(.primary))
        let downs = events.filter { $0.type == .leftMouseDown }
        #expect(downs.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 2])
    }

    @Test func losingThePointerReleasesTheButton() {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        input.handle(.pointerExited)
        input.handle(.pointerUp(.primary)) // The router's later release must not repeat it.
        #expect(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(!input.isDown)
    }

    @Test func scrollsAtThePointer() throws {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.scroll(SIMD2(0, 0.1))) // No pointer yet: nothing to scroll.
        #expect(events.isEmpty)
        input.handle(.pointerMoved(to: SIMD2(0.25, 0.25)))
        input.handle(.scroll(SIMD2(0, 0.1)))
        let scroll = try #require(events.last)
        #expect(scroll.type == .scrollWheel)
        #expect(scroll.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 90)
    }

    @Test func withoutAccessibilityNothingIsPosted() {
        var events: [CGEvent] = []
        let input = makeInput(trusted: false) { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        #expect(events.isEmpty)
        #expect(!input.isDown)
    }
}
