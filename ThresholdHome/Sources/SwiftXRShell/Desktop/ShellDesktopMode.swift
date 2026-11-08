@preconcurrency import ApplicationServices
import Foundation
import Metal
import SwiftXR

@MainActor
final class ShellDesktopMode {
    private static let desktopWidthEnvironmentVariable = "SWIFTXR_DESKTOP_WIDTH_METERS"
    private static let minimumDesktopWidthMeters: Float = 0.75
    private static let maximumDesktopWidthMeters: Float = 8.0

    private let session: XRSession
    private let swapchain: XRSwapchain
    private let trackedInput: ShellTrackedInput
    private let onRequestHome: () -> Void
    private let interaction = XRPanelInteraction()
    private var input: DesktopPointerInput?

    private var setupTask: Task<Void, Never>?
    private var capture: DesktopCapture?
    private var renderer: DesktopRenderer?
    private(set) var isReady = false
    private(set) var failure: Error?

    init(
        session: XRSession,
        swapchain: XRSwapchain,
        trackedInput: ShellTrackedInput,
        onRequestHome: @escaping () -> Void
    ) {
        self.session = session
        self.swapchain = swapchain
        self.trackedInput = trackedInput
        self.onRequestHome = onRequestHome
        interaction.handler = { [weak self] event in self?.input?.handle(event) }
    }

    func activate() {
        failure = nil
        isReady = false

        setupTask?.cancel()
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                print("[desktop] discovering primary display…")
                let capture = try await DesktopCapture.primaryDisplay(device: session.device)
                try Task.checkCancellation()

                let widthMeters = Self.configuredDesktopWidthMeters()
                let renderer = try DesktopRenderer(
                    device: session.device,
                    swapchain: swapchain,
                    capturedPixelSize: capture.pixelSize,
                    widthMeters: widthMeters
                )
                try await capture.start()
                try Task.checkCancellation()

                self.capture = capture
                self.renderer = renderer
                // Controller pointing posts mouse events, which needs the
                // Accessibility permission; ask once, as Browser does.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                let trusted = AXIsProcessTrustedWithOptions(options)
                self.input = DesktopPointerInput(displayFrame: capture.displayFrame)
                trackedInput.reset(interaction: interaction)
                self.isReady = true
                print(trusted
                    ? "[desktop] controller: trigger clicks/drags · right stick scrolls · PS returns Home"
                    : "[desktop] controller pointing needs Accessibility permission for SwiftXR Shell")
                print(
                    "[desktop] capture started: " +
                    "\(capture.display.width)x\(capture.display.height)"
                )
                print(
                    String(
                        format: "[desktop] panel size: %.2f m × %.2f m",
                        renderer.geometry.widthMeters,
                        renderer.geometry.heightMeters
                    )
                )
                print("[desktop] Escape returns to SwiftXR Shell Home")
            } catch is CancellationError {
                return
            } catch {
                self.failure = error
                fputs("swiftxr-shell desktop: \(error)\n", stderr)
                self.onRequestHome()
            }
        }
    }

    func deactivate() {
        setupTask?.cancel()
        setupTask = nil
        isReady = false
        trackedInput.suspend(interaction: interaction)
        input?.cancel()
        input = nil

        if let capture {
            Task { @MainActor in
                try? await capture.stop()
            }
        }
        capture = nil
        renderer = nil
    }

    func renderFrame() throws {
        let desktopFrame = try capture?.latestFrame()
        let renderer = self.renderer
        if session.state != .focused { trackedInput.suspend(interaction: interaction) }
        var commands = TrackedPanelCommands()

        _ = try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
            if let renderer {
                ShellStageAnchor.shared.updateIfNeeded(from: frame)
                if input != nil {
                    commands = try trackedInput.update(
                        frame: frame,
                        interaction: interaction,
                        model: ShellStageAnchor.shared.modelMatrix(
                            worldWidth: renderer.geometry.widthMeters,
                            textureAspect: renderer.geometry.aspectRatio,
                            distance: ShellStageAnchor.defaultDistance
                        ),
                        faceButtonsSelect: false
                    )
                }
                try renderer.encode(
                    frame: frame,
                    swapchainTexture: texture,
                    desktopTexture: desktopFrame?.texture,
                    commandBuffer: commandBuffer,
                    pointerPosition: interaction.pointerPosition
                )
            } else {
                try Self.clearFrame(
                    frame: frame,
                    texture: texture,
                    commandBuffer: commandBuffer
                )
            }
        }
        if commands.recenter { ShellStageAnchor.shared.requestRecenter() }
        // Only PS leaves Desktop: Options is held to recentre, and Create has
        // no meaning on the Mac desktop.
        if commands.home { onRequestHome() }
    }

    private static func configuredDesktopWidthMeters() -> Float {
        let environment = ProcessInfo.processInfo.environment
        guard
            let value = environment[desktopWidthEnvironmentVariable],
            let width = Float(value),
            width.isFinite
        else {
            return DesktopRenderer.defaultWidthMeters
        }

        return min(max(width, minimumDesktopWidthMeters), maximumDesktopWidthMeters)
    }

    static func clearFrame(
        frame: XRFrame,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }
        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.012,
                green: 0.016,
                blue: 0.026,
                alpha: 1
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw DesktopRendererError.renderEncoderCreationFailed
            }
            encoder.endEncoding()
        }
    }
}
