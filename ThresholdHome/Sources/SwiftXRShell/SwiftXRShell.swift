import AppKit
import Combine
import CVizBridge
import Foundation
import GameController
import QuartzCore
import SwiftUI
import SwiftXR
import ThresholdCore

@MainActor
private final class SwiftXRShellAppDelegate: NSObject, NSApplicationDelegate {
    private enum Mode: Equatable {
        case home
        case video
        case desktop
        case browser
        case external
    }

    private var mode: Mode = .home {
        didSet { if mode != oldValue { updateCompanionWindow() } }
    }
    private var companionWindow: ShellCompanionWindow?
    /// Threshold XR's view of Home: status out, the status window's actions in.
    private var homeControl: HomeControlServer?
    private var mouseCaptureEnabled = true
    private var foregroundVRAppName: String?
    private var startupError: String?

    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?
    private var trackedInput: ShellTrackedInput?
    private var trackedEscapeMonitor: Any?

    private var homePanel: XRSwiftUIPanel<ShellHomeView>?
    private var homeRenderer: ShellPanelRenderer?
    private var homeFrameLoop: HomeFrameLoop?
    private var homeContentRevision = 0
    private var homePointerCapture: XRMacPointerCapture?
    private var configuredHomeController: GCController?

    private var videoMode: ShellVideoMode?
    private var browserMode: (any ShellBrowserPresentation)?
    private let browserApplication = BrowserApplication()
    private let vizBrowserClient = VizBrowserClient()
    private var browserHomeMonitor: Any?
    private var desktopMode: ShellDesktopMode?
    private var desktopEscapeMonitor: Any?
    private let externalLauncher = ExternalOpenXRLauncher()
    private let externalActivityMonitor = ExternalOpenXRActivityMonitor()
    private var systemOverlay: ShellSystemOverlayController?
    private var shellModel: ShellModel?
    private var resumeModeAfterObservedExternal: Mode?
    private var externalApplicationsEnabled = false
    private var modelObservations: Set<AnyCancellable> = []

    private var exitRequested = false
    private var xrActivity: NSObjectProtocol?
    private var referenceSpaceGeneration: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShellDiagnostics.shared.startLogging()
        let companion = ShellCompanionWindow()
        companion.onAction = { [weak self] action in self?.handleCompanionAction(action) }
        companionWindow = companion
        // Menus stay installed when managed: their key equivalents (⇧⌘M to
        // release the mouse, ⌘1–4) still work while Home is frontmost.
        companion.installMenus()
        if !ShellLaunch.isManaged { companion.showWindow(nil) }
        startHomeControl()
        updateCompanionWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        do {
            try setUpShell()
            scheduleFrameStep()
        } catch {
            startupError = String(describing: error)
            fputs("[shell] startup connection unavailable: \(error)\n", stderr)
            updateCompanionWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        do {
            switch mode {
            case .home:
                try startHomePointerCaptureIfReady()
            case .video, .desktop, .browser, .external:
                break
            }
        } catch {
            fail(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        homeControl?.stop()
        stopHomeFrameLoop()
        if let xrActivity { ProcessInfo.processInfo.endActivity(xrActivity) }
        systemOverlay?.shutdown()
        externalActivityMonitor.shutdown()
        externalLauncher.shutdown()
        shellModel?.steamLibrary.shutdown()
        removeDesktopEscapeMonitor()
        if let trackedEscapeMonitor { NSEvent.removeMonitor(trackedEscapeMonitor) }
        homePointerCapture?.stop()
        videoMode?.shutdown()
        desktopMode?.deactivate()
        browserMode?.deactivate()
        vizBrowserClient.shutdown()
        removeBrowserHomeMonitor()
        if session?.isRunning == true && !exitRequested {
            try? session?.requestExit()
        }
    }

    private func setUpShell() throws {
        // The system overlay must continue to receive its configured controller
        // button while the launched XR application owns macOS foreground focus.
        GCController.shouldMonitorBackgroundEvents = true

        let settings: ShellSettings
        do {
            settings = try ShellSettings.load()
            print(
                "[overlay] system menu trigger: \(settings.systemOverlayButton.rawValue) ("
                    + ShellSettings.settingsURL.path + ")"
            )
        } catch {
            settings = ShellSettings()
            print("[overlay] could not load settings; using Home/PS button: \(error)")
        }

        let model = ShellModel(
            steamLibrary: SteamGameLibrary(configuration: settings.steamGames)
        )
        self.shellModel = model
        try createShellXRPresentation(model: model)
        trackedEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  self.trackedInput?.usesControllers == true,
                  self.mode == .home || self.mode == .video else { return event }
            DispatchQueue.main.async {
                if self.mode == .video { self.returnHome() }
                else if self.mode == .home {
                    do { try self.requestSessionExitIfNeeded() } catch { self.fail(error) }
                }
            }
            return nil
        }
        observeModelChanges(model)
        model.steamLibrary.reload()

        let systemOverlay = ShellSystemOverlayController(
            triggerButton: settings.systemOverlayButton
        )
        systemOverlay.onAction = { [weak self] action in
            self?.handleSystemOverlayAction(action)
        }
        self.systemOverlay = systemOverlay

        Task { @MainActor [weak model] in
            let loaded = await Task.detached(priority: .userInitiated) {
                ExternalApplicationCatalog.load()
            }.value
            model?.replaceExternalApplications(loaded.applications)
            print(
                "[shell] loaded \(loaded.applications.count) external application(s) from "
                    + "\(ExternalApplicationCatalog.catalogURL.path) and threshold-runtime"
            )
            for problem in loaded.problems {
                print("[shell] could not read \(problem.source.rawValue): \(problem.message)")
            }
        }

        externalLauncher.onSwitchedToApplication = { [weak self] client in
            guard let self else { return }
            self.foregroundVRAppName = client.name
            print("[shell] external application is primary/focused: \(client.name)")
            if self.mode == .home {
                // Started from Home with Home kept on screen until now.
                self.leaveHomeInput()
                self.mode = .external
            }
            self.shellModel?.externalActivity?.phase = .running
            self.systemOverlay?.foregroundApplicationDidBecomeActive()
        }
        externalLauncher.onReturnedToShell = { [weak self] in
            self?.returnHomeFromExternal()
        }
        externalLauncher.onError = { [weak self] error in
            self?.handleExternalLaunchError(error)
        }

        externalActivityMonitor.canTakeOver = { [weak self] in
            guard let self else { return false }
            guard !self.externalLauncher.isRunningExternalApplication else {
                return false
            }

            // The first automatic handoff milestone deliberately covers the
            // shell modes used for browser/WebXR entry. Video resume semantics
            // need separate treatment because playback state should be
            // preserved rather than restarted.
            return self.mode == .home || self.mode == .desktop || self.mode == .browser
        }
        externalActivityMonitor.onExternalSessionBecameActive = { [weak self] client in
            self?.yieldToObservedExternalSession(client)
        }
        externalActivityMonitor.onExternalSessionEnded = { [weak self] client in
            self?.resumeAfterObservedExternalSession(client)
        }
        externalActivityMonitor.onSuppressedExternalSessionEnded = { [weak self] client in
            self?.observedExternalSessionEndedWhileInShell(client)
        }
        externalActivityMonitor.onError = { error in
            fputs("swiftxr-shell external activity monitor: \(error)\n", stderr)
        }
        if externalApplicationsEnabled {
            externalActivityMonitor.start()
        }

        model.commandHandler = { [weak self] command in
            guard let self else { return }
            switch command {
            case let .launch(application):
                do {
                    try self.launch(application)
                } catch {
                    if case .external = application.kind {
                        self.handleExternalLaunchError(error)
                    } else {
                        self.fail(error)
                    }
                }
            case .stopExternalApplication:
                self.stopExternalApplication()
            case .settings:
                print("Shell settings requested (not implemented yet)")
            }
        }

        print("SwiftXR Shell ready")
        print("Video and Desktop run in-process on the Shell OpenXR session")
        updateCompanionWindow()
    }

    private func createShellXRPresentation(model: ShellModel) throws {
        let capabilities = try XRRuntime.capabilities()
        try capabilities.requireMetal()

        let instance = try XRInstance(applicationName: "SwiftXR Shell")
        print("Runtime: \(instance.runtime.name) \(instance.runtime.version)")

        // Establish the primary session before opening a separate runtime-
        // control connection, especially when launchd is starting Monado.
        let session = try instance.system().makeSession()
        externalApplicationsEnabled = canUseMonadoApplicationHandoff(
            runtimeName: instance.runtime.name
        )
        model.setExternalApplicationsEnabled(externalApplicationsEnabled)

        let trackedInput = try ShellTrackedInput(session: session)
        let swapchain = try session.makeStereoSwapchain()
        // Home keeps its 1280×720 point layout; a wider panel is drawn at a
        // proportionally higher resolution so text stays as sharp (scale 1 at
        // the original 2.4 m, 1.25 → 1600×900 at the 3.0 m default).
        let homeScale = min(max((1280 * CGFloat(ShellSettings.homeWidthMeters) / 2.4).rounded() / 1280, 1), 2)
        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(width: 1280, height: 720),
            scale: homeScale
        ) {
            ShellHomeView(model: model)
        }
        let renderer = try ShellPanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture,
            worldWidth: ShellSettings.homeWidthMeters
        )
        print(String(format: "[shell] Home panel: %.2f m wide, rendered at %.0f×%.0f",
                     ShellSettings.homeWidthMeters, 1280 * homeScale, 720 * homeScale))
        let pointerCapture = XRMacPointerCapture(panel: panel)
        panel.refreshesOnPointerMovement = false
        panel.usesImmutableTextures = true

        self.instance = instance
        self.session = session
        self.trackedInput = trackedInput
        self.swapchain = swapchain
        self.homePanel = panel
        self.homeRenderer = renderer
        self.homePointerCapture = pointerCapture
    }

    private func canUseMonadoApplicationHandoff(runtimeName: String) -> Bool {
        guard runtimeName.localizedCaseInsensitiveContains("monado") else {
            print(
                "[shell] external OpenXR application launch disabled: "
                    + "active runtime is not Monado (\(runtimeName))"
            )
            return false
        }

        do {
            let monado = try XRMonadoRuntimeControl()
            _ = try monado.refreshClients()
            print("[shell] Monado/libmonado application handoff available")
            return true
        } catch {
            print(
                "[shell] external OpenXR application launch disabled: "
                    + "libmonado runtime control unavailable (\(error))"
            )
            return false
        }
    }

    private func launch(_ application: ShellApplication) throws {
        switch application.kind {
        case .videoPlayer:
            try enterVideo()
        case .virtualDesktop:
            enterDesktop()
        case .browser:
            try enterBrowser()
        case .browserViz:
            try enterBrowser(viz: true)
        case .resumeObservedExternal:
            try resumeObservedExternalSession()
        case let .external(external):
            guard externalApplicationsEnabled else {
                print(
                    "[shell] ignored external application launch: "
                        + "Monado/libmonado handoff is unavailable"
                )
                return
            }
            try enterExternal(application, external: external)
        }
    }

    private func enterVideo() throws {
        guard
            mode == .home,
            let session,
            let swapchain,
            let trackedInput
        else { return }

        leaveHomeInput()

        let video = try ShellVideoMode(
            session: session,
            swapchain: swapchain,
            trackedInput: trackedInput,
            onRequestHome: { [weak self] in
                DispatchQueue.main.async { self?.returnHome() }
            }
        )
        videoMode = video
        video.mouseCaptureEnabled = mouseCaptureEnabled
        video.onStatusChanged = { [weak self] in self?.updateCompanionWindow() }
        mode = .video
        try video.activate()
    }

    private func enterDesktop() {
        guard
            mode == .home,
            let session,
            let swapchain,
            let trackedInput
        else { return }

        leaveHomeInput()
        installDesktopEscapeMonitor()

        let desktop = ShellDesktopMode(
            session: session,
            swapchain: swapchain,
            trackedInput: trackedInput,
            onRequestHome: { [weak self] in
                DispatchQueue.main.async {
                    // A capture that could not start is reported in Home and
                    // to Threshold XR, rather than silently returning.
                    let failure = self?.desktopMode?.failure
                    self?.returnHome()
                    if let failure { self?.shellModel?.launchError = ShellLaunch.describeCaptureFailure(failure, mode: "Desktop") }
                }
            }
        )
        desktopMode = desktop
        mode = .desktop
        desktop.activate()
        print("[shell] Desktop active — Escape returns to launcher")
    }

    private func enterBrowser(viz: Bool = false) throws {
        guard mode == .home, let session, let swapchain, let trackedInput else { return }
        // Build renderers before leaving Home so setup errors leave its input intact.
        let requestHome: () -> Void = { [weak self] in DispatchQueue.main.async { self?.returnHome() } }
        let failure: (Error) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.mode == .browser else { return }
                self.returnHome()
                self.shellModel?.launchError = error.localizedDescription
            }
        }
        let browser: any ShellBrowserPresentation
        if viz {
            browser = try ShellVizBrowserMode(session: session, swapchain: swapchain, trackedInput: trackedInput,
                client: vizBrowserClient, onRequestHome: requestHome, onFailure: failure)
        } else {
            browser = ShellBrowserMode(session: session, swapchain: swapchain, trackedInput: trackedInput,
                browser: browserApplication, onRequestHome: requestHome, onFailure: failure)
        }
        leaveHomeInput()
        browser.onStatusChanged = { [weak self] in self?.updateCompanionWindow() }
        browserMode = browser
        mode = .browser
        installBrowserHomeMonitor()
        browser.activate()
        print("[shell] Browser \(viz ? "(Viz)" : "(window)") active — PS button or ⇧⌘H returns Home")
    }

    private func enterExternal(
        _ application: ShellApplication,
        external: ExternalOpenXRApplication
    ) throws {
        guard mode == .home, !externalLauncher.isRunningExternalApplication else { return }

        resumeModeAfterObservedExternal = nil
        if !external.showsHomeWhileStarting {
            leaveHomeInput()
            mode = .external
        }
        shellModel?.externalActivity = ShellExternalActivity(
            applicationID: application.id,
            title: application.title,
            phase: .starting
        )

        // Create the overlay client before the launcher snapshots Monado's
        // existing clients, so it can never be mistaken for the new foreground
        // application. Overlay support is optional: a failure here should not
        // stop the requested XR application from launching.
        do {
            try systemOverlay?.prepare(
                applicationTitle: application.title,
                actions: [.resume, .quitApplication]
            )
        } catch {
            systemOverlay?.shutdown()
            print("[overlay] unavailable for this launch: \(error)")
        }

        do {
            try externalLauncher.launch(application, external: external)
            print("[shell] launched \(application.title); waiting for its Monado client")
        } catch {
            systemOverlay?.shutdown()
            shellModel?.externalActivity = nil
            if mode == .external {
                finishReturningHome()
            }
            throw error
        }
    }

    /// Stop from Home, while an app started from there is still starting.
    private func stopExternalApplication() {
        guard externalLauncher.isRunningExternalApplication else { return }
        do {
            try externalLauncher.terminateForegroundApplication()
            shellModel?.externalActivity?.phase = .stopping
            print("[shell] requested termination of \(externalLauncher.currentApplicationTitle ?? "app")")
        } catch {
            fputs("swiftxr-shell stop: \(error)\n", stderr)
        }
    }

    private func returnHome() {
        guard mode != .home else { return }

        switch mode {
        case .video:
            videoMode?.shutdown()
            videoMode = nil
        case .desktop:
            desktopMode?.deactivate()
            desktopMode = nil
            removeDesktopEscapeMonitor()
        case .browser:
            browserMode?.deactivate()
            browserMode = nil
            removeBrowserHomeMonitor()
        case .external:
            return
        case .home:
            break
        }

        finishReturningHome()
    }

    private func returnHomeFromExternal() {
        shellModel?.externalActivity = nil
        systemOverlay?.shutdown()
        guard mode == .external else { return }
        resumeModeAfterObservedExternal = nil
        finishReturningHome()
    }

    private func yieldToObservedExternalSession(_ client: XRMonadoClient) {
        foregroundVRAppName = client.name
        guard resumeModeAfterObservedExternal == nil else { return }
        guard mode == .home || mode == .desktop || mode == .browser else { return }

        let previousMode = mode
        switch previousMode {
        case .home:
            leaveHomeInput()
        case .desktop:
            // ScreenCaptureKit and the desktop renderer are unnecessary while
            // another client owns the HMD. Stop them to reduce GPU/bandwidth
            // load; the desktop itself (and Chromium window) remains untouched.
            desktopMode?.deactivate()
            removeDesktopEscapeMonitor()
        case .browser:
            browserMode?.deactivate()
            removeBrowserHomeMonitor()
            if browserMode is ShellVizBrowserMode { installVizImmersiveKeyboardMonitor() }
        case .video, .external:
            return
        }

        shellModel?.clearResumeObservedExternal()
        homePanel?.invalidate()
        resumeModeAfterObservedExternal = previousMode
        mode = .external

        do {
            try systemOverlay?.prepare(
                applicationTitle: client.name,
                actions: [.resume, .desktop, .home]
            )
            systemOverlay?.foregroundApplicationDidBecomeActive()
        } catch {
            systemOverlay?.shutdown()
            print("[overlay] unavailable for observed external session: \(error)")
        }

        print(
            "[shell] yielding \(previousMode) to independently-started OpenXR client "
                + "\(client.id): \(client.name)"
        )
    }

    private func resumeAfterObservedExternalSession(_ client: XRMonadoClient) {
        guard mode == .external, let previousMode = resumeModeAfterObservedExternal else {
            return
        }

        systemOverlay?.shutdown()
        shellModel?.clearResumeObservedExternal()
        homePanel?.invalidate()
        resumeModeAfterObservedExternal = nil
        mode = previousMode
        NSApplication.shared.activate(ignoringOtherApps: true)

        switch previousMode {
        case .home:
            homePanel?.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
            homePanel?.invalidate()
            do {
                try startHomePointerCaptureIfReady()
            } catch {
                fail(error)
                return
            }

        case .desktop:
            installDesktopEscapeMonitor()
            desktopMode?.activate()

        case .browser:
            installBrowserHomeMonitor()
            browserMode?.activate()

        case .video, .external:
            break
        }

        print("[shell] resumed \(previousMode) after \(client.name) left immersive XR")
    }

    private func observedExternalSessionEndedWhileInShell(_ client: XRMonadoClient) {
        shellModel?.clearResumeObservedExternal()
        homePanel?.invalidate()
        print("[shell] \(client.name) ended its suppressed immersive session")
    }

    private func resumeObservedExternalSession() throws {
        guard mode == .home else { return }
        _ = try externalActivityMonitor.resumeSuppressedSession()
    }

    private func handleSystemOverlayAction(_ action: ShellSystemOverlayAction) {
        switch action {
        case .resume:
            return

        case .quitApplication:
            quitExternalApplicationFromOverlay()

        case .desktop, .home:
            guard resumeModeAfterObservedExternal != nil else { return }

            do {
                let client = try externalActivityMonitor.returnForegroundSessionToShell()
                systemOverlay?.shutdown()
                resumeModeAfterObservedExternal = nil

                shellModel?.showResumeObservedExternal(title: client.name)
                homePanel?.invalidate()

                // Any existing Desktop mode was suspended when the external
                // session took over. Recreate it if Desktop was selected so
                // ScreenCaptureKit starts from a clean state.
                desktopMode?.deactivate()
                desktopMode = nil
                removeDesktopEscapeMonitor()
                browserMode?.deactivate()
                browserMode = nil
                removeBrowserHomeMonitor()

                mode = .home
                if action == .desktop {
                    enterDesktop()
                } else {
                    finishReturningHome()
                }

                print(
                    "[overlay] returned to SwiftXR \(action == .desktop ? "Desktop" : "Home"); "
                        + "\(client.name) remains available to resume"
                )
            } catch {
                systemOverlay?.actionRequestFailed()
                fputs("swiftxr-shell overlay handoff: \(error)\n", stderr)
            }
        }
    }

    private func finishReturningHome() {
        foregroundVRAppName = nil
        mode = .home
        NSApplication.shared.activate(ignoringOtherApps: true)
        homePanel?.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
        homePanel?.invalidate()
        do {
            try startHomePointerCaptureIfReady()
        } catch {
            fail(error)
            return
        }
        print("[shell] returned Home")
    }

    private func quitExternalApplicationFromOverlay() {
        guard mode == .external else { return }

        do {
            let title = externalLauncher.currentApplicationTitle ?? "OpenXR application"
            try externalLauncher.terminateForegroundApplication()
            shellModel?.externalActivity?.phase = .stopping
            print("[overlay] requested termination of \(title)")
        } catch {
            systemOverlay?.actionRequestFailed()
            fputs("swiftxr-shell overlay quit: \(error)\n", stderr)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not quit OpenXR application"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func handleExternalLaunchError(_ error: Error) {
        fputs("swiftxr-shell external launch: \(error)\n", stderr)
        systemOverlay?.shutdown()
        shellModel?.externalActivity = nil

        if mode == .external {
            finishReturningHome()
        }

        shellModel?.launchError = error.localizedDescription
        homePanel?.invalidate()
    }

    /// The Home panel only re-rasterizes on input or invalidate(); redraw it
    /// when the model changes (install progress, game list, launch state).
    private func observeModelChanges(_ model: ShellModel) {
        let redraw: () -> Void = { [weak self] in
            // objectWillChange fires before the change; SwiftUI applies it on
            // the next pass of the run loop.
            DispatchQueue.main.async {
                self?.homeContentRevision += 1
                self?.homePanel?.invalidate()
                self?.updateCompanionWindow()
            }
        }
        model.objectWillChange.sink { _ in redraw() }.store(in: &modelObservations)
        model.steamLibrary.objectWillChange.sink { _ in redraw() }.store(in: &modelObservations)
    }

    private func updateCompanionWindow() {
        let foreground: String
        let detail: String
        if session == nil {
            foreground = startupError == nil ? "Connecting…" : "Headset unavailable"
            detail = startupError == nil ? "Starting OpenXR" : "Mode → Connect / Retry Headset (⌘K)"
        } else {
            switch mode {
            case .home:
                foreground = "Home"
                if let activity = shellModel?.externalActivity { detail = "Starting \(activity.title)…" }
                else if shellModel?.launchError != nil { detail = "Launch failed — details are shown in Home" }
                else { detail = "SwiftXR Shell" }
            case .video:
                foreground = "Video"
                detail = videoMode?.statusTitle ?? "Video library"
            case .desktop:
                foreground = "Desktop"
                detail = "Your Mac in VR"
            case .browser:
                foreground = browserMode is ShellVizBrowserMode ? "Browser (Viz)" : "Browser"
                detail = browserMode?.status ?? "Chromium"
            case .external:
                foreground = foregroundVRAppName ?? externalLauncher.currentApplicationTitle ?? "VR application"
                detail = "External OpenXR application"
            }
        }
        let status = ShellCompanionStatus(
            foreground: foreground, detail: detail,
            runtime: instance?.runtime.name ?? startupError ?? "Starting OpenXR…",
            input: mode == .browser ? "Sense pointer · physical keyboard · ⇧⌘H Home"
                : trackedInput?.usesControllers == true ? "Sense / tracked controllers"
                : mouseCaptureEnabled ? "Mouse fallback · ⇧⌘M releases capture" : "Desktop mouse released",
            canGoHome: mode != .home && (mode != .external || resumeModeAfterObservedExternal != nil),
            canSwitchModes: session != nil && mode != .external && shellModel?.externalActivity == nil,
            canStopApp: externalLauncher.isRunningExternalApplication,
            mouseCaptureEnabled: mouseCaptureEnabled,
            canRetryConnection: session == nil
        )
        companionWindow?.update(status)
        let homeMode: HomeStatus.Mode
        if session == nil {
            homeMode = startupError == nil ? .connecting : .unavailable
        } else {
            switch mode {
            case .home: homeMode = .home
            case .video: homeMode = .video
            case .desktop: homeMode = .desktop
            case .browser: homeMode = .browser
            case .external: homeMode = .external
            }
        }
        homeControl?.publish(HomeStatus(
            mode: homeMode, foreground: status.foreground, detail: status.detail,
            runtime: status.runtime, input: status.input, canGoHome: status.canGoHome,
            canSwitchModes: status.canSwitchModes, canStopApp: status.canStopApp,
            mouseCaptureEnabled: status.mouseCaptureEnabled, canRetryConnection: status.canRetryConnection,
            notice: shellModel?.launchError
        ))
    }

    private func startHomeControl() {
        let server = HomeControlServer { [weak self] command in
            MainActor.assumeIsolated { self?.handleHomeCommand(command) }
        }
        do {
            try server.start()
            homeControl = server
            print("[shell] control channel: \(server.socketURL.path)")
        } catch {
            fputs("[shell] control channel unavailable: \(error.localizedDescription)\n", stderr)
        }
    }

    private func handleHomeCommand(_ command: HomeCommand) {
        switch command {
        case .home: handleCompanionAction(.home)
        case .video: handleCompanionAction(.video)
        case .desktop: handleCompanionAction(.desktop)
        case .browser: handleCompanionAction(.browser)
        case .recenter: handleCompanionAction(.recenter)
        case .stopApp: handleCompanionAction(.stopApp)
        case .toggleMouse: handleCompanionAction(.toggleMouse)
        case .retryConnection: handleCompanionAction(.retryConnection)
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    private func handleCompanionAction(_ action: ShellCompanionWindow.Action) {
        do {
            switch action {
            case .home:
                if mode == .external { handleSystemOverlayAction(.home) } else { returnHome() }
            case .video:
                guard mode != .external && mode != .video else { return }
                returnHome()
                try enterVideo()
            case .desktop:
                guard mode != .external && mode != .desktop else { return }
                returnHome()
                enterDesktop()
            case .browser:
                guard mode != .external && mode != .browser else { return }
                returnHome()
                try enterBrowser()
            case .recenter:
                ShellStageAnchor.shared.requestRecenter()
            case .stopApp:
                stopExternalApplication()
            case .toggleMouse:
                mouseCaptureEnabled.toggle()
                videoMode?.mouseCaptureEnabled = mouseCaptureEnabled
                if !mouseCaptureEnabled { homePointerCapture?.stop() }
                else if mode == .home { try startHomePointerCaptureIfReady() }
            case .showWindow: break
            case .retryConnection:
                guard session == nil else { return }
                startupError = nil
                updateCompanionWindow()
                do {
                    modelObservations.removeAll()
                    try setUpShell()
                    scheduleFrameStep()
                } catch {
                    startupError = String(describing: error)
                    fputs("[shell] reconnect failed: \(error)\n", stderr)
                }
            }
        } catch { handleExternalLaunchError(error) }
        updateCompanionWindow()
    }

    private func stopHomeFrameLoop() {
        homeFrameLoop?.stop()
        homeFrameLoop = nil
    }

    private func leaveHomeInput() {
        stopHomeFrameLoop()
        homePointerCapture?.stop()
        if let homePanel { trackedInput?.reset(interaction: homePanel.interaction) }
        clearHomeControllerHandlers()
    }

    @objc
    private func frameStep() {
        let frameStarted = CACurrentMediaTime()
        guard let session, let swapchain else {
            scheduleFrameStep(after: 0.02)
            return
        }

        do {
            let needsActivity = mode != .external
            if needsActivity && xrActivity == nil {
                xrActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "Presenting an interactive OpenXR environment"
                )
            } else if !needsActivity, let xrActivity {
                ProcessInfo.processInfo.endActivity(xrActivity)
                self.xrActivity = nil
            }
            if mode == .home {
                try serviceHomeUI(session: session, swapchain: swapchain)
                ShellDiagnostics.shared.recordFrame(mode: "home UI", startedAt: frameStarted)
                scheduleFrameStep(after: 1.0 / 120)
                return
            }
            try session.pollEvents()
            if referenceSpaceGeneration != session.referenceSpaceChangeGeneration {
                referenceSpaceGeneration = session.referenceSpaceChangeGeneration
                ShellStageAnchor.shared.requestRecenter(atTime: session.referenceSpaceChangeTime)
                print("[shell] following runtime reference-space reset")
            }

            if session.shouldExit {
                systemOverlay?.shutdown()
                externalActivityMonitor.shutdown()
                externalLauncher.shutdown()
                homePointerCapture?.stop()
                videoMode?.shutdown()
                desktopMode?.deactivate()
                browserMode?.deactivate()
                vizBrowserClient.shutdown()
                removeBrowserHomeMonitor()
                NSApplication.shared.terminate(nil)
                return
            }

            // The Shell's primary session can become non-visible/non-running
            // while an external primary app owns the HMD. Drive the independent
            // overlay session before checking the primary Shell session state.
            if mode == .external || externalLauncher.isRunningExternalApplication {
                try systemOverlay?.renderFrame()
            }

            guard session.isRunning else {
                scheduleFrameStep(after: 0.005)
                return
            }

            switch mode {
            case .home:
                break // Home is driven by its dedicated XR worker above.
            case .video:
                try videoMode?.renderFrame()
            case .desktop:
                try desktopMode?.renderFrame()
            case .browser:
                try browserMode?.renderFrame()
            case .external:
                _ = try session.nextFrame()
            }

            ShellDiagnostics.shared.recordFrame(mode: String(describing: mode), startedAt: frameStarted)
            scheduleFrameStep()
        } catch {
            fail(error)
        }
    }

    private func serviceHomeUI(session: XRSession, swapchain: XRSwapchain) throws {
        guard let panel = homePanel, let renderer = homeRenderer,
              let pointerCapture = homePointerCapture, let trackedInput else { return }
        if homeFrameLoop == nil {
            let loop = HomeFrameLoop(session: session, swapchain: swapchain,
                renderer: renderer, input: trackedInput.runtimeInput, texture: panel.texture,
                onUpdates: { [weak self] updates in self?.handleHomeUpdates(updates) },
                onError: { [weak self] error in
                    guard let self, self.mode == .home else { return }
                    self.fail(error)
                })
            homeFrameLoop = loop
            loop.start()
        }
        if pointerCapture.escapeRequested { try requestSessionExitIfNeeded(); return }
        if trackedInput.isFocused && !trackedInput.usesControllers {
            pointerCapture.poll()
            if let pad = configuredHomeController?.extendedGamepad,
               abs(pad.rightThumbstick.yAxis.value) > 0.18 {
                panel.interaction.scroll(SIMD2(0, pad.rightThumbstick.yAxis.value / 120 * 4))
            }
        }
        let refreshStarted = CACurrentMediaTime()
        let refreshed = try panel.refreshIfNeeded()
        ShellDiagnostics.shared.recordPanelUpdate(seconds: CACurrentMediaTime() - refreshStarted, refreshed: refreshed)
        homeFrameLoop?.publish(texture: panel.texture, mousePointer: panel.interaction.pointerPosition,
                               scrollInfo: panel.scrollInfo, contentRevision: homeContentRevision,
                               mouseButtonDown: NSEvent.pressedMouseButtons != 0)
    }

    private func handleHomeUpdates(_ updates: [HomeFrameUpdate]) {
        guard mode == .home, let panel = homePanel,
              let pointerCapture = homePointerCapture, let trackedInput else { return }
        for update in updates {
            if update.shouldExit {
                NSApplication.shared.terminate(nil)
                return
            }
            if referenceSpaceGeneration != update.referenceGeneration {
                referenceSpaceGeneration = update.referenceGeneration
                ShellStageAnchor.shared.requestRecenter(atTime: update.referenceTime)
                print("[shell] following runtime reference-space reset")
            }
            guard update.focused, let frame = update.frame, let controllers = update.controllers else {
                trackedInput.suspend(interaction: panel.interaction)
                pointerCapture.stop()
                clearHomeControllerHandlers()
                continue
            }
            let commands = trackedInput.apply(state: controllers, frame: frame,
                interaction: panel.interaction,
                model: ShellStageAnchor.shared.modelMatrix(worldWidth: ShellSettings.homeWidthMeters, textureAspect: 1280.0 / 720))
            if shellModel?.usesTrackedControllers != commands.usesControllers {
                shellModel?.usesTrackedControllers = commands.usesControllers
            }
            if commands.recenter { ShellStageAnchor.shared.requestRecenter() }
            if commands.usesControllers || !trackedInput.isFocused {
                pointerCapture.stop()
                clearHomeControllerHandlers()
            } else {
                do { try startHomePointerCaptureIfReady() } catch { fail(error); return }
                configureHomeControllerIfNeeded(panel: panel)
            }
        }
    }

    private func configureHomeControllerIfNeeded(panel: XRSwiftUIPanel<ShellHomeView>) {
        let controller = GCController.current ?? GCController.controllers().first
        guard controller !== configuredHomeController else { return }

        clearHomeControllerHandlers()
        configuredHomeController = controller
        guard let pad = controller?.extendedGamepad else { return }

        func onPress(
            _ button: GCControllerButtonInput,
            _ action: @escaping @MainActor () -> Void
        ) {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                DispatchQueue.main.async {
                    guard self?.mode == .home else { return }
                    action()
                }
            }
        }

        onPress(pad.dpad.up) { panel.interaction.navigate(.up) }
        onPress(pad.dpad.down) { panel.interaction.navigate(.down) }
        onPress(pad.dpad.left) { panel.interaction.navigate(.left) }
        onPress(pad.dpad.right) { panel.interaction.navigate(.right) }
        onPress(pad.buttonA) { panel.interaction.select() }
        onPress(pad.buttonB) { panel.interaction.back() }
        onPress(pad.buttonMenu) { panel.interaction.select() }
    }

    private func clearHomeControllerHandlers() {
        guard let pad = configuredHomeController?.extendedGamepad else {
            configuredHomeController = nil
            return
        }
        pad.dpad.up.pressedChangedHandler = nil
        pad.dpad.down.pressedChangedHandler = nil
        pad.dpad.left.pressedChangedHandler = nil
        pad.dpad.right.pressedChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonB.pressedChangedHandler = nil
        pad.buttonMenu.pressedChangedHandler = nil
        configuredHomeController = nil
    }

    private func installBrowserHomeMonitor() {
        removeBrowserHomeMonitor()
        // Chromium owns keyboard focus. Escape must remain available to dismiss
        // browser UI and leave WebXR; use a separate global Home shortcut.
        browserHomeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 4,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] else { return }
            DispatchQueue.main.async { self?.returnHome() }
        }
    }

    private func installVizImmersiveKeyboardMonitor() {
        // A headless browser never becomes the Mac's foreground app. Continue
        // delivering physical keys while its independent WebXR session presents.
        removeBrowserHomeMonitor()
        browserHomeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.mode == .external,
                  self.resumeModeAfterObservedExternal == .browser,
                  self.browserMode is ShellVizBrowserMode else { return event }
            if event.modifierFlags.contains(.command), event.keyCode == 12 { return event }
            if event.type == .keyDown && event.keyCode == 4 &&
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
                DispatchQueue.main.async { self.handleSystemOverlayAction(.home) }
                return nil
            }
            self.vizBrowserClient.send(kind: UInt32(event.type == .keyDown ? SXR_VIZ_KEY_DOWN : SXR_VIZ_KEY_UP), event: event)
            return nil
        }
    }

    private func removeBrowserHomeMonitor() {
        if let browserHomeMonitor {
            NSEvent.removeMonitor(browserHomeMonitor)
            self.browserHomeMonitor = nil
        }
    }

    private func installDesktopEscapeMonitor() {
        removeDesktopEscapeMonitor()
        desktopEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            DispatchQueue.main.async { self?.returnHome() }
            return nil
        }
    }

    private func removeDesktopEscapeMonitor() {
        if let desktopEscapeMonitor {
            NSEvent.removeMonitor(desktopEscapeMonitor)
            self.desktopEscapeMonitor = nil
        }
    }

    private func startHomePointerCaptureIfReady() throws {
        guard
            mode == .home,
            mouseCaptureEnabled,
            trackedInput?.usesControllers != true,
            trackedInput?.isFocused == true,
            NSApplication.shared.isActive,
            let homePointerCapture,
            !homePointerCapture.isCaptureRequested
        else { return }

        try homePointerCapture.start()
        guard homePointerCapture.isCaptured else {
            throw XRMacPointerCaptureError.applicationNotActive
        }
    }

    private func requestSessionExitIfNeeded() throws {
        stopHomeFrameLoop()
        guard !exitRequested else { return }
        exitRequested = true
        systemOverlay?.shutdown()
        externalActivityMonitor.shutdown()
        externalLauncher.shutdown()
        homePointerCapture?.stop()
        videoMode?.shutdown()
        desktopMode?.deactivate()
        browserMode?.deactivate()
        vizBrowserClient.shutdown()
        removeBrowserHomeMonitor()

        if session?.isRunning == true {
            try session?.requestExit()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func scheduleFrameStep(after delay: TimeInterval = 0) {
        perform(
            #selector(frameStep),
            with: nil,
            afterDelay: delay,
            inModes: [.common, .eventTracking]
        )
    }

    private func fail(_ error: Error) {
        stopHomeFrameLoop()
        systemOverlay?.shutdown()
        externalActivityMonitor.shutdown()
        externalLauncher.shutdown()
        homePointerCapture?.stop()
        videoMode?.shutdown()
        desktopMode?.deactivate()
        browserMode?.deactivate()
        vizBrowserClient.shutdown()
        removeBrowserHomeMonitor()
        removeDesktopEscapeMonitor()
        fputs("swiftxr-shell: \(error)\n", stderr)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SwiftXR Shell"
        alert.informativeText = String(describing: error)
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}

enum ShellLaunch {
    /// True when Home runs as Threshold XR's helper: its bundle sets
    /// LSUIElement, or it was started with --managed.
    static let isManaged = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
        || CommandLine.arguments.contains("--managed")

    /// The name macOS lists this app under in Privacy & Security.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SwiftXR Shell"
    }

    static func describeCaptureFailure(_ error: Error, mode: String) -> String {
        let ns = error as NSError
        // ScreenCaptureKit's "user declined TCCs" error.
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            return "\(mode) needs Screen Recording permission. Allow \(appName) in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Home."
        }
        return "\(mode) could not start: \(error.localizedDescription)"
    }
}

@main
struct SwiftXRShell {
    @MainActor
    static func main() {
        let application = XRMacApplication.shared
        // Inside Threshold XR, Home runs without a Dock icon or status
        // window; Threshold XR's Home tab shows its status instead.
        application.setActivationPolicy(ShellLaunch.isManaged ? .accessory : .regular)

        let appDelegate = SwiftXRShellAppDelegate()
        application.delegate = appDelegate

        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}
