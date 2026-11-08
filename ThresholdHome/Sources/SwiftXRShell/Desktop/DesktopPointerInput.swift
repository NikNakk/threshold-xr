import AppKit
import ApplicationServices
import SwiftXR

/// Controller pointing for the virtual desktop.
///
/// Unlike the browser, which addresses one Chromium window, the desktop panel
/// shows the whole display, so events are posted system-wide at the matching
/// point: the Mac's own cursor moves and clicks whatever is under it. Posting
/// needs the Accessibility permission, as the browser's input does.
@MainActor
final class DesktopPointerInput {
    /// Moves smaller than this (in points) are ignored while no button is
    /// held, so controller tracking jitter does not keep taking the cursor
    /// away from the physical mouse.
    static let jitterDeadband: CGFloat = 2

    /// The captured display's frame in global Quartz points.
    var displayFrame: CGRect
    private var lastPoint: CGPoint?
    private var postedPoint: CGPoint?
    private(set) var isDown = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private let source = CGEventSource(stateID: .hidSystemState)
    private let isTrusted: () -> Bool
    private let deliver: (CGEvent) -> Void
    private let now: () -> TimeInterval

    init(displayFrame: CGRect,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         deliver: ((CGEvent) -> Void)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.displayFrame = displayFrame
        self.isTrusted = isTrusted
        self.deliver = deliver ?? { $0.post(tap: .cghidEventTap) }
        self.now = now
    }

    func handle(_ event: XRPanelInteractionEvent) {
        guard isTrusted() else { cancel(); return }
        switch event {
        case let .pointerMoved(uv):
            let point = BrowserCoordinates.point(uv: uv, frame: displayFrame)
            lastPoint = point
            if isDown {
                mouse(.leftMouseDragged)
            } else if let posted = postedPoint,
                      hypot(point.x - posted.x, point.y - posted.y) < Self.jitterDeadband {
                return
            } else {
                mouse(.mouseMoved)
            }
        case .pointerDown(.primary):
            guard let point = lastPoint, !isDown else { return }
            let time = now()
            if time - lastClickTime < NSEvent.doubleClickInterval,
               hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 5 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = time
            lastClickPoint = point
            isDown = true
            mouse(.leftMouseDown)
        case .pointerUp(.primary):
            if isDown { mouse(.leftMouseUp); isDown = false }
        case .pointerExited:
            cancel()
            lastPoint = nil
        case let .scroll(delta):
            guard let lastPoint else { return }
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(delta.y * 900), wheel2: Int32(delta.x * 900), wheel3: 0) {
                event.location = lastPoint
                deliver(event)
            }
        default:
            break
        }
    }

    /// Releases a held button where the pointer last was, so losing tracking
    /// or leaving Desktop never leaves the Mac with the mouse button down.
    func cancel() {
        guard isDown else { return }
        mouse(.leftMouseUp)
        isDown = false
    }

    private func mouse(_ type: CGEventType) {
        guard let lastPoint,
              let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: lastPoint, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        deliver(event)
        postedPoint = lastPoint
    }
}
