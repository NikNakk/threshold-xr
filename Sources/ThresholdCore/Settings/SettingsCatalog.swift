import Foundation

/// The settings Threshold XR exposes. Monado entries are real options read by
/// the installed service (defaults from the Monado fork's source); the
/// Settings screen also checks each variable against the installed binary.
public enum SettingsCatalog {
    public static let monado: [SettingDescriptor] = [
        SettingDescriptor(
            id: "monado.refreshRate",
            title: "Display refresh rate",
            detail: "Refresh rate Monado requests from the PS VR2 display. Display default leaves the mode unchanged.",
            group: "Display",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "XRT_MACOS_REFRESH_RATE_HZ"),
            type: .choice([
                SettingChoice(.integer(0), "Display default"),
                SettingChoice(.integer(90), "90 Hz"),
                SettingChoice(.integer(120), "120 Hz"),
            ]),
            defaultValue: .integer(0),
            applyMode: .serviceReload
        ),
        SettingDescriptor(
            id: "monado.floorEyeHeight",
            title: "Floor calibration eye height",
            detail: "Your standing eye height. Monado uses it with the head pose to place the STAGE floor automatically. 0 turns automatic floor calibration off.",
            group: "Tracking space",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "XRT_FLOOR_EYE_HEIGHT_M"),
            type: .decimal(range: 0...2.5, step: 0.01, unit: "m"),
            defaultValue: .decimal(0),
            applyMode: .serviceReload
        ),
        SettingDescriptor(
            id: "monado.floorAlign",
            title: "Centre stage on calibration",
            detail: "When calibrating the floor, also centre the STAGE under the head and face it the head's direction.",
            group: "Tracking space",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "XRT_FLOOR_ALIGN"),
            type: .toggle,
            defaultValue: .bool(true),
            applyMode: .serviceReload
        ),
        SettingDescriptor(
            id: "monado.stageRecenter",
            title: "Options-button stage recentre",
            detail: "Holding the right Sense controller's Options button recentres the stage and re-measures the floor.",
            group: "Tracking space",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "XRT_PSSENSE_STAGE_RECENTER"),
            type: .toggle,
            defaultValue: .bool(false),
            applyMode: .serviceReload
        ),
        SettingDescriptor(
            id: "monado.stageRecenterHold",
            title: "Recentre hold time",
            detail: "How long Options must be held to recentre.",
            group: "Tracking space",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "XRT_PSSENSE_STAGE_RECENTER_HOLD_MS"),
            type: .integer(range: 200...5000, unit: "ms"),
            defaultValue: .integer(1000),
            applyMode: .serviceReload,
            isAdvanced: true
        ),
        SettingDescriptor(
            id: "monado.exitWhenIdle",
            title: "Stop when idle",
            detail: "Exit the service once every application has disconnected, releasing the headset. launchd starts it again when an application connects.",
            group: "Service lifecycle",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "IPC_EXIT_WHEN_IDLE"),
            type: .toggle,
            defaultValue: .bool(false),
            applyMode: .serviceReload,
            isAdvanced: true
        ),
        SettingDescriptor(
            id: "monado.exitWhenIdleDelay",
            title: "Idle delay",
            detail: "How long the service waits with no applications before exiting.",
            group: "Service lifecycle",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "IPC_EXIT_WHEN_IDLE_DELAY_MS"),
            type: .integer(range: 0...600_000, unit: "ms"),
            defaultValue: .integer(5000),
            applyMode: .serviceReload,
            isAdvanced: true
        ),
        SettingDescriptor(
            id: "monado.exitOnDisplayLoss",
            title: "Stop when the headset display disconnects",
            detail: "Shut the service down when the PS VR2 display goes away, so it is not left holding the headset's USB interfaces.",
            group: "Service lifecycle",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "XRT_MACOS_EXIT_ON_DISPLAY_LOSS"),
            type: .toggle,
            defaultValue: .bool(false),
            applyMode: .serviceReload,
            isAdvanced: true
        ),
        SettingDescriptor(
            id: "monado.sense6DoF",
            title: "Sense controller optical tracking",
            detail: "Track the Sense controllers in 6DoF with the headset cameras. Experimental; requires a calibration file.",
            group: "Controllers",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "PSVR2_SENSE_6DOF"),
            type: .toggle,
            defaultValue: .bool(false),
            applyMode: .serviceReload,
            isAdvanced: true
        ),
        SettingDescriptor(
            id: "monado.sense6DoFCalibration",
            title: "Camera calibration file",
            detail: "Absolute path of the mode-4 camera calibration used by Sense optical tracking.",
            group: "Controllers",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "PSVR2_SENSE_6DOF_CALIBRATION"),
            type: .filePath(allowedExtensions: ["json"]),
            defaultValue: nil,
            applyMode: .serviceReload,
            isAdvanced: true
        ),
        SettingDescriptor(
            id: "monado.timingTrace",
            title: "PS VR2 timing traces",
            detail: "Write per-frame timing CSV files for diagnosis. Adds disk I/O during sessions.",
            group: "Diagnostics",
            owner: .component(.monado),
            storage: .monadoServiceEnvironment(variable: "PSVR2_TIMING_TRACE"),
            type: .toggle,
            defaultValue: .bool(false),
            applyMode: .serviceReload,
            isAdvanced: true,
            isDeveloper: true
        ),
    ]

    public static let app: [SettingDescriptor] = [
        SettingDescriptor(
            id: AppPreferences.Key.automaticRuntimeQueries,
            title: "Read runtime details automatically",
            detail: "Ask Monado for its clients and devices while an application is connected. Threshold XR never connects when that could start the service or trigger its idle exit.",
            group: "Monitoring",
            owner: .thresholdXR,
            storage: .appPreferences(key: AppPreferences.Key.automaticRuntimeQueries),
            type: .toggle,
            defaultValue: .bool(true),
            applyMode: .live
        ),
        SettingDescriptor(
            id: AppPreferences.Key.refreshInterval,
            title: "Status refresh interval",
            detail: "How often service status is checked while Threshold XR is open.",
            group: "Monitoring",
            owner: .thresholdXR,
            storage: .appPreferences(key: AppPreferences.Key.refreshInterval),
            type: .integer(range: 1...60, unit: "s"),
            defaultValue: .integer(3),
            applyMode: .live
        ),
        SettingDescriptor(
            id: AppPreferences.Key.workspaceRoot,
            title: "Developer workspace",
            detail: "Folder containing source checkouts and development builds, used to find components that are not installed elsewhere.",
            group: "Component discovery",
            owner: .thresholdXR,
            storage: .appPreferences(key: AppPreferences.Key.workspaceRoot),
            type: .directoryPath,
            defaultValue: .text("~/Code"),
            applyMode: .live
        ),
        SettingDescriptor(
            id: AppPreferences.Key.windowsRigRoot,
            title: "Windows compatibility folder",
            detail: "Folder containing the Windows game runner, prefixes and Windows OpenVR runtimes.",
            group: "Component discovery",
            owner: .thresholdXR,
            storage: .appPreferences(key: AppPreferences.Key.windowsRigRoot),
            type: .directoryPath,
            defaultValue: .text("~/Windows"),
            applyMode: .live
        ),
    ]

    public static var all: [SettingDescriptor] { app + monado }

    public static func descriptor(id: String) -> SettingDescriptor? { all.first { $0.id == id } }
}
