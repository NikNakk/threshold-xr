import AppKit
import SwiftXR
import Testing
@testable import SwiftXRShell

@Suite("Desktop controller pointer", .serialized)
@MainActor
struct DesktopPointerInputTests {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// Exact-position tests turn smoothing off; dedicated tests cover it.
    func makeInput(trusted: Bool = true, smoothing: Bool = false,
                   events: @escaping (CGEvent) -> Void,
                   clock: @escaping () -> TimeInterval = { 0 }) -> DesktopPointerInput {
        var tuning = DesktopPointerInput.Tuning.standard
        if !smoothing { tuning.smoothing = nil }
        return DesktopPointerInput(displayFrame: display, tuning: tuning, isTrusted: { trusted },
                                   deliver: events, now: clock)
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

    @Test func smallMovementWhileHeldIsStillAClickAtThePressedPoint() throws {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        // About 9 points: within the ~18 point slop on a 1512 point display.
        input.handle(.pointerMoved(to: SIMD2(0.506, 0.502)))
        #expect(input.displayedUV.map { abs($0.x - 0.5) < 0.0001 } == true, "the dot stays where the click is")
        input.handle(.pointerUp(.primary))
        #expect(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        let down = try #require(events.first { $0.type == .leftMouseDown })
        let up = try #require(events.last)
        #expect(down.location == up.location)
    }

    @Test func movingBeyondTheSlopStartsADrag() {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        input.handle(.pointerMoved(to: SIMD2(0.506, 0.5)))
        #expect(!events.contains { $0.type == .leftMouseDragged })
        input.handle(.pointerMoved(to: SIMD2(0.53, 0.5))) // ~45 points
        input.handle(.pointerMoved(to: SIMD2(0.531, 0.5))) // once dragging, every move counts
        #expect(events.filter { $0.type == .leftMouseDragged }.count == 2)
        input.handle(.pointerUp(.primary))
        #expect(events.last.map { abs($0.location.x - 0.531 * 1511) < 0.01 } == true)
    }

    @Test func pressLandsWhereTheAimWasBeforeTheTriggerPull() throws {
        var events: [CGEvent] = []
        var time: TimeInterval = 0
        let input = makeInput(events: { events.append($0) }, clock: { time })
        input.handle(.pointerMoved(to: SIMD2(0.40, 0.40)))
        time = 0.03
        input.handle(.pointerMoved(to: SIMD2(0.40, 0.40)))
        time = 0.08 // the trigger pull tips the controller
        input.handle(.pointerMoved(to: SIMD2(0.40, 0.42)))
        time = 0.09
        input.handle(.pointerDown(.primary))
        let down = try #require(events.first { $0.type == .leftMouseDown })
        #expect(abs(down.location.y - 0.40 * 981) < 0.01)
    }

    @Test func smoothingSettlesHandTremor() throws {
        /// Cursor moves posted during the second of two seconds of ±4 point
        /// tremor at 90 Hz, once any initial settling is over.
        func settledMoves(smoothing: Bool) -> (Int, DesktopPointerInput) {
            var events: [CGEvent] = []
            var time: TimeInterval = 0
            let input = makeInput(smoothing: smoothing, events: { events.append($0) }, clock: { time })
            var countAtOneSecond = 0
            for frame in 0..<180 {
                time = Double(frame) / 90
                if frame == 90 { countAtOneSecond = events.count }
                let wobble = Float(frame % 2 == 0 ? 4 : -4) / 1511
                input.handle(.pointerMoved(to: SIMD2(0.5 + wobble, 0.5 - wobble)))
            }
            return (events.count - countAtOneSecond, input)
        }
        let (raw, _) = settledMoves(smoothing: false)
        let (smoothed, input) = settledMoves(smoothing: true)
        #expect(raw == 90, "unsmoothed tremor moves the cursor every frame")
        #expect(smoothed == 0, "smoothed tremor stays inside the hover deadband")
        let uv = try #require(input.displayedUV)
        #expect(abs(uv.x - 0.5) * 1511 < 1.5)
    }

    @Test func smoothingStillFollowsDeliberateMovement() throws {
        var time: TimeInterval = 0
        let input = makeInput(smoothing: true, events: { _ in }, clock: { time })
        input.handle(.pointerMoved(to: SIMD2(0.2, 0.5)))
        // Sweep 0.4 of the display (about 600 points) in a third of a second.
        for frame in 1...30 {
            time = Double(frame) / 90
            input.handle(.pointerMoved(to: SIMD2(0.2 + 0.4 * Float(frame) / 30, 0.5)))
        }
        let uv = try #require(input.displayedUV)
        #expect(abs(uv.x - 0.6) * 1511 < 40, "lag behind a fast sweep stays small")
    }

    @Test func trackingJitterDoesNotMoveTheCursorWhileHovering() {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerMoved(to: SIMD2(0.5005, 0.5))) // below the hover deadband
        #expect(events.count == 1)
        input.handle(.pointerMoved(to: SIMD2(0.52, 0.5)))
        #expect(events.count == 2)
    }

    @Test func secondQuickClickIsADoubleClick() {
        var events: [CGEvent] = []
        var time: TimeInterval = 10
        let input = makeInput(events: { events.append($0) }, clock: { time })
        input.handle(.pointerMoved(to: SIMD2(0.3, 0.3)))
        input.handle(.pointerDown(.primary)); input.handle(.pointerUp(.primary))
        time += 0.1
        input.handle(.pointerMoved(to: SIMD2(0.302, 0.301))) // a little wobble between clicks
        input.handle(.pointerDown(.primary)); input.handle(.pointerUp(.primary))
        let downs = events.filter { $0.type == .leftMouseDown }
        #expect(downs.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 2])
    }

    @Test func gripRightClicksWhereTheAimWasBeforeTheSqueeze() throws {
        var events: [CGEvent] = []
        var time: TimeInterval = 0
        let input = makeInput(events: { events.append($0) }, clock: { time })
        input.secondaryClick()
        #expect(events.isEmpty, "no pointer, no click")
        input.handle(.pointerMoved(to: SIMD2(0.30, 0.30)))
        time = 0.03
        input.handle(.pointerMoved(to: SIMD2(0.30, 0.30)))
        time = 0.08 // squeezing tips the controller
        input.handle(.pointerMoved(to: SIMD2(0.30, 0.33)))
        time = 0.09
        input.secondaryClick()
        let right = events.filter { $0.type == .rightMouseDown || $0.type == .rightMouseUp }
        #expect(right.map(\.type) == [.rightMouseDown, .rightMouseUp])
        let down = try #require(right.first)
        #expect(abs(down.location.y - 0.30 * 981) < 0.01)
        #expect(down.getIntegerValueField(.mouseEventButtonNumber) == 1)
    }

    @Test func gripDoesNothingDuringALeftButtonPress() {
        var events: [CGEvent] = []
        let input = makeInput { events.append($0) }
        input.handle(.pointerMoved(to: SIMD2(0.5, 0.5)))
        input.handle(.pointerDown(.primary))
        input.secondaryClick()
        #expect(!events.contains { $0.type == .rightMouseDown })
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
        #expect(input.displayedUV == nil)
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
