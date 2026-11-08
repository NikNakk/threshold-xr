import AppKit
import ApplicationServices
import SwiftXR

/// Controller pointing for the virtual desktop.
///
/// Unlike the browser, which addresses one Chromium window, the desktop panel
/// shows the whole display, so events are posted system-wide at the matching
/// point: the Mac's own cursor moves and clicks whatever is under it. Posting
/// needs the Accessibility permission, as the browser's input does.
///
/// A hand-held ray is never perfectly still, and a desktop treats any motion
/// with the button down as a drag. Three measures make clicks reliable:
///  - the aim is smoothed with a One Euro filter (strong at rest, light when
///    moving fast, so pointing stays responsive);
///  - a press lands where the pointer was just before the trigger pull, which
///    tips the controller;
///  - after a press the cursor stays put until the aim moves beyond a slop
///    distance, so small movements still release as a click.
@MainActor
final class DesktopPointerInput {
    struct Tuning: Sendable {
        /// Moves smaller than this (points) are ignored while hovering, so a
        /// resting controller does not take the cursor from a physical mouse.
        var hoverDeadband: CGFloat = 2
        /// Drag threshold as a fraction of the display width (at least 10 pt).
        var clickSlopFraction: CGFloat = 0.012
        /// How far back a press looks for the aim before the trigger pull.
        var pressRewind: TimeInterval = 0.06
        /// One Euro filter parameters (points and seconds); nil disables it.
        var smoothing: OneEuroFilter.Parameters? = .init(minimumCutoff: 1.5, beta: 0.01, derivativeCutoff: 1)

        static let standard = Tuning()
    }

    /// The captured display's frame in global Quartz points.
    var displayFrame: CGRect
    let tuning: Tuning

    private var filter: OneEuroFilter?
    private var lastPoint: CGPoint?
    private var postedPoint: CGPoint?
    private var history: [(time: TimeInterval, point: CGPoint)] = []
    private var pressPoint: CGPoint?
    private var dragging = false
    private(set) var isDown = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private let source = CGEventSource(stateID: .hidSystemState)
    private let isTrusted: () -> Bool
    private let deliver: (CGEvent) -> Void
    private let now: () -> TimeInterval

    init(displayFrame: CGRect,
         tuning: Tuning = .standard,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         deliver: ((CGEvent) -> Void)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.displayFrame = displayFrame
        self.tuning = tuning
        self.isTrusted = isTrusted
        self.deliver = deliver ?? { $0.post(tap: .cghidEventTap) }
        self.now = now
    }

    var clickSlop: CGFloat { max(10, displayFrame.width * tuning.clickSlopFraction) }

    /// Where to draw the pointer on the panel: the smoothed aim, or the
    /// pressed point while a click is held within the slop.
    var displayedUV: SIMD2<Float>? {
        guard let point = (isDown && !dragging ? pressPoint : nil) ?? lastPoint else { return nil }
        let width = max(displayFrame.width - 1, 1), height = max(displayFrame.height - 1, 1)
        return SIMD2(Float((point.x - displayFrame.minX) / width), Float((point.y - displayFrame.minY) / height))
    }

    func handle(_ event: XRPanelInteractionEvent) {
        guard isTrusted() else { cancel(); return }
        switch event {
        case let .pointerMoved(uv):
            let time = now()
            let point = smoothed(BrowserCoordinates.point(uv: uv, frame: displayFrame), at: time)
            lastPoint = point
            history.append((time, point))
            history.removeAll { time - $0.time > 0.5 }
            if isDown {
                if !dragging, let press = pressPoint, distance(point, press) < clickSlop { return }
                dragging = true
                mouse(.leftMouseDragged, at: point)
            } else if let posted = postedPoint, distance(point, posted) < tuning.hoverDeadband {
                return
            } else {
                mouse(.mouseMoved, at: point)
            }
        case .pointerDown(.primary):
            guard lastPoint != nil, !isDown else { return }
            let time = now()
            let point = rewoundPoint(at: time)
            if time - lastClickTime < NSEvent.doubleClickInterval, distance(point, lastClickPoint) < clickSlop {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = time
            lastClickPoint = point
            pressPoint = point
            dragging = false
            isDown = true
            mouse(.leftMouseDown, at: point)
        case .pointerUp(.primary):
            release()
        case .pointerExited:
            cancel()
            lastPoint = nil
            filter = nil
            history.removeAll()
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

    /// Releases a held button, so losing tracking or leaving Desktop never
    /// leaves the Mac with the mouse button down.
    func cancel() { release() }

    private func release() {
        guard isDown else { return }
        // Within the slop the release completes a click at the pressed point.
        let point = dragging ? lastPoint : pressPoint
        if let point { mouse(.leftMouseUp, at: point) }
        isDown = false
        dragging = false
        pressPoint = nil
    }

    private func smoothed(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        guard let parameters = tuning.smoothing else { return point }
        if filter == nil { filter = OneEuroFilter(parameters: parameters) }
        return filter!.filter(point, at: time)
    }

    /// The aim from just before the trigger pull: the oldest sample within the
    /// rewind window, or the latest if there is none.
    private func rewoundPoint(at time: TimeInterval) -> CGPoint {
        history.first { time - $0.time <= tuning.pressRewind }?.point ?? lastPoint ?? .zero
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func mouse(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        deliver(event)
        postedPoint = point
    }
}

/// The One Euro filter (Casiez, Roussel and Vogel, CHI 2012): a low-pass
/// filter whose cutoff rises with speed, removing jitter at rest without
/// adding lag to fast movements.
struct OneEuroFilter {
    struct Parameters: Sendable {
        /// Cutoff (Hz) at rest; lower is smoother.
        var minimumCutoff: Double
        /// How quickly the cutoff rises with speed (per point/second).
        var beta: Double
        /// Cutoff (Hz) for the speed estimate.
        var derivativeCutoff: Double
    }

    let parameters: Parameters
    private var previous: CGPoint?
    private var previousDerivative = CGPoint.zero
    private var previousTime: TimeInterval?

    init(parameters: Parameters) { self.parameters = parameters }

    mutating func filter(_ value: CGPoint, at time: TimeInterval) -> CGPoint {
        guard let previous, let previousTime else {
            self.previous = value
            self.previousTime = time
            return value
        }
        // Samples arrive once per headset frame; guard against equal times.
        let dt = CGFloat(time > previousTime ? time - previousTime : 1.0 / 90)
        let derivative = CGPoint(x: (value.x - previous.x) / dt, y: (value.y - previous.y) / dt)
        let dAlpha = Self.alpha(cutoff: CGFloat(parameters.derivativeCutoff), dt: dt)
        let smoothedDerivative = CGPoint(
            x: previousDerivative.x + dAlpha * (derivative.x - previousDerivative.x),
            y: previousDerivative.y + dAlpha * (derivative.y - previousDerivative.y))
        let speed = hypot(smoothedDerivative.x, smoothedDerivative.y)
        let cutoff = CGFloat(parameters.minimumCutoff) + CGFloat(parameters.beta) * speed
        let alpha = Self.alpha(cutoff: cutoff, dt: dt)
        let result = CGPoint(x: previous.x + alpha * (value.x - previous.x),
                             y: previous.y + alpha * (value.y - previous.y))
        self.previous = result
        self.previousDerivative = smoothedDerivative
        self.previousTime = time
        return result
    }

    private static func alpha(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
