# Threshold XR design: installer, agent, sessions and immersive shell

Status: proposal after Milestone 1. Everything below is grounded in the infrastructure inspected on 7 November 2026; file names refer to the user's existing repositories.

## 1. What exists today

| Piece | Where it lives | What Threshold XR relies on |
| --- | --- | --- |
| Monado service | `~/.local/monado-psvr2` (prefix), LaunchAgent `org.freedesktop.monado.service` | On-demand Mach service `org.freedesktop.monado.metal-ipc`; `RunAtLoad=false`; idle exit after `IPC_EXIT_WHEN_IDLE_DELAY_MS`; exits when the display is lost; logs in `~/Library/Logs/Monado/`. |
| Monado configuration | The LaunchAgent's `EnvironmentVariables` | `monado-service-xpc-control install` and `scripts/macos/install-local-preferences.py` both preserve it. There is no `config_v0.json`. |
| Client environment | LaunchAgent `org.freedesktop.monado.client-environment` | Runs `launchctl setenv XR_RUNTIME_JSON …` and `XRT_MACOS_CLIENT_COMPOSITOR=1` at login. |
| System registration | `/usr/local/share/openxr/1/active_runtime.json` → the prefix's manifest (root-owned symlink) | Read-only. |
| Session control | libmonado API 1.8: client list, primary/focus, I/O blocks, devices, recentre, reference-space offsets; `monado-ctl` | SwiftXR's `XRMonadoRuntimeControl` already wraps the client parts. |
| Threshold Home | SwiftXR Shell (`/Applications/SwiftXR Shell.app`, `com.nickkennedy.swiftxr-shell`) | Already does launch, focus handoff, return-on-exit, overlay dashboard, and the catalog `~/Library/Application Support/SwiftXRShell/apps.json`. |
| Native Alyx | `~/Code/alyx-native` (`run-alyx`, `run-alyx-profile`, `source-revisions.json`) | `play` runs on the installed Monado service (`--monado-service installed`, which checks the service and runtime tags match). `play-recorded` and the diagnostic profiles start a temporary service from a matching build. The play profile names the KosmicKrisp ICD, xrizer library and host. xrizer reports the host executable's name (`alyx_host`) as the OpenXR application name. |
| Wine path | `~/Code/wine-crossover/runtime*`, DXMT installed inside them, `~/Windows/run-windows-game.zsh`, Steam Play tool | The runner selects the x86_64 Monado client (`build/x86_64/openxr_monado-dev.json`), which must match the service's build tag. |

## 2. Milestone 1 decisions worth keeping

- **Monado owns its settings.** Threshold XR edits the agent's environment in place (with a backup), shows when saved values differ from the loaded job, and asks for an explicit reload. It never mirrors those values into its own preferences.
- **Readiness checks don't disturb the service.** They use the launchd PID plus `libproc` socket inspection. libmonado is used only when another client is connected, because a connect when Monado is idle starts it over XPC, and a disconnect that leaves no clients arms idle exit.
- **No new persistent process.** Everything that must outlive the app already does: launchd keeps Monado alive, and Threshold Home is an ordinary app.
- **The app only reads the system OpenXR registration.** Changing it later will be a separate, explicit, privileged action (see §5.6).

## 3. Threshold Agent

There is no agent in Milestone 1, and none is needed for these tasks:

| Task | Handled by |
| --- | --- |
| Keep Monado available | launchd on-demand activation (existing) |
| Return to Home after an app exits | Threshold Home (existing SwiftXR Shell behaviour) |
| Set the client environment at login | The existing client-environment LaunchAgent |
| Show status | The desktop app, while it is open |

An agent becomes justified only if one of these is needed:

1. **Background updates.** Downloading or building components on a schedule, or while the app is closed.
2. **Policy that must run with no UI**, such as the *Runtime only* mode needing to keep a recentre or brightness policy applied across service restarts.
3. **A privileged helper** for the one root-owned operation: replacing `/usr/local/share/openxr/1/active_runtime.json`. That would be an `SMAppService` daemon that does nothing else. It should be done on demand rather than kept resident.

If an agent is added, it should be an `SMAppService.agent` bundled inside `Threshold XR.app` and registered only when the user turns on a feature that needs it. It would link ThresholdCore and talk to the app over XPC. Monado must never depend on it.

## 4. Session management and the three modes

### Current behaviour

SwiftXR Shell connects as an ordinary OpenXR client. For a launch it starts, it takes a snapshot of libmonado's client list, starts the process, detects the new non-overlay client, and sets it primary and focused. When that session stops presenting, the shell makes itself primary again. Separately, it watches for `sessionActive` clients it did not launch (WebXR, for example) and hands over to them, then restores its previous mode when they finish. An `XR_EXTX_overlay` session provides the dashboard (Resume, Desktop, Home, Quit).

### Proposed modes

| Mode | Monado | Threshold Home | Who starts the app | Return behaviour |
| --- | --- | --- | --- | --- |
| Runtime only | On demand; idle exit as configured | Not running | User or Threshold XR | The app exits, Monado idles out |
| Threshold Home | Started by the shell's own connection | Running and primary | The shell (catalog) or user | The shell restores itself (existing) |
| Direct launch | On demand | Optional: if it is running, it yields | Threshold XR | If the shell is running, it resumes; otherwise none |

Plan for integration, without changing the session code:

1. **Milestone 2 (Direct launch).** Threshold XR starts an application process with its profile's environment and waits for its client to appear. That wait uses the same passive socket count, then a libmonado query, which is safe once the new client is connected. Threshold XR does **not** set primary/focus itself. If Threshold Home is running, its existing watcher for independently started sessions already hands over. If not, the app is the only client and becomes primary anyway. One owner of focus avoids races between the two controllers.
2. **Shared catalog.** Threshold XR becomes the editor of `apps.json` (adding entries, profiles and requirements), and SwiftXR Shell stays its reader. A version field added to the format would let both agree on the schema.
3. **Extract shared code.** Move `XRMonadoRuntimeControl` and Threshold's `LibMonado` into a small `MonadoControl` Swift package with no OpenXR loader dependency, used by SwiftXR Shell and ThresholdCore. Do this in a dedicated change to SwiftXR, not in this repository.
4. **Home ⇄ desktop control.** "Return to Home" and "Quit app" from the desktop need a channel to the running shell. Prefer a small XPC or distributed-notification interface on the shell over Threshold XR changing primary/focus behind its back.

## 5. Manifest-driven installer (proposal)

### 5.1 Concepts

- **Component**: something with a role and a way to be installed. Roles stay distinct because they install differently:
  - `runtime`: Monado, a prefix plus a LaunchAgent
  - `openvr-runtime`: xrizer, a library loaded by applications; there are native and Windows variants
  - `graphics-translation`: DXMT, installed *into* a Wine runtime
  - `vulkan-driver`: KosmicKrisp, an ICD manifest selected per application
  - `compatibility-layer`: a Wine runtime
  - `integration`: the Wine XR bridge or Steam Play tool
  - `app-host`: the Alyx and Quest hosts, normally supplied by the guest framework (§6)
  - `shell`: Threshold Home
- **Artifact**: one built output with an architecture (`arm64`, `x86_64`, `win64`) and an install target.
- **Release**: a version of a component with artifacts, provenance and requirements.
- **Stack**: a known-working set of releases, e.g. "PS VR2 + Alyx, 2026-10-31". Stacks are what users pick.
- **Profile**: a per-application recipe (§6). It names a stack, or a minimum set of component versions, plus environment and arguments.

### 5.2 Manifest shape (JSON, signed)

```json
{
  "schema": 1,
  "components": {
    "monado": {
      "role": "runtime",
      "sources": [
        {"type": "release", "repo": "NikNakk/monado", "asset": "monado-macos-arm64-{version}.tar.zst"},
        {"type": "git", "repo": "https://github.com/NikNakk/monado", "build": "cmake-preset:macos-arm64"}
      ],
      "install": {"prefix": "~/Library/Application Support/Threshold XR/Components/monado/{version}",
                  "activate": "launchagent:org.freedesktop.monado.service"},
      "detect": {"version": {"embeddedString": "^v\\d+\\.\\d+\\.\\d+(-\\d+-g[0-9a-f]+)?$", "in": "bin/monado-service"}}
    },
    "monado-wine-client": {
      "role": "runtime-client", "arch": "x86_64",
      "requires": [{"component": "monado", "sameBuildTag": true}]
    },
    "dxmt": {
      "role": "graphics-translation",
      "installInto": {"component": "wine", "paths": ["lib/wine/x86_64-unix/winemetal.so", "lib/wine/x86_64-windows/d3d11.dll"]}
    },
    "kosmickrisp": {"role": "vulkan-driver", "install": {"icd": "kosmickrisp_icd.aarch64.json"}}
  },
  "stacks": {
    "psvr2-stable-2026-11": {
      "channel": "stable",
      "releases": {"monado": "v25.1.0-2479-gae2b6d059", "kosmickrisp": "kk-integration@0913fce7", "xrizer": "integration-gaze-02d4229"},
      "verified": {"date": "2026-10-31", "evidence": "alyx 29-minute headset session"}
    }
  }
}
```

### 5.3 Install locations and activation

- **Versioned installs.** Each release installs into its own versioned directory under `~/Library/Application Support/Threshold XR/Components/<id>/<version>/`. A `current` pointer is changed atomically, so rollback is just moving the pointer back. Nothing is deleted until the user prunes old versions.
- **Monado activation** means running that version's own `monado-service-xpc-control install`, which preserves the existing environment. Threshold XR never writes a new plist from scratch. The client-environment agent's `XR_RUNTIME_JSON` gets the same pointer treatment.
- **Existing manual installs** (like `~/.local/monado-psvr2` today) are *adopted*, not moved. They are recorded as `external` releases with their detected version and path. They can be activated and rolled back to, but Threshold XR never modifies or deletes them.
- **Lockstep pairs.** Monado service and its Wine x86_64 client must share a build tag. The manifest expresses this as `sameBuildTag`, and the installer refuses to activate one without the other. Milestone 1 already warns about this mismatch.

### 5.4 Version detection and constraints

Every component declares how to detect its version without running it:

- embedded strings (Monado tag, Wine's `wine-X.Y`)
- ICD `api_version`
- bundle `CFBundleShortVersionString`
- `manifest.txt` (xrizer Windows)
- git `HEAD` for source builds

Constraints use semver ranges where upstream versions mean something (Wine, the OpenXR loader). Otherwise they use exact build identities or git revisions (Monado fork tags, KosmicKrisp, xrizer).

### 5.5 Channels and developer builds

- **stable**: stacks with recorded hardware evidence.
- **experimental**: newer stacks that are built and pass automated checks but have no headset sign-off.
- **local**: anything the developer points at. A local branch build is registered as a release with `source: {"type": "local", "path": "~/Code/monado-2", "revision": "<HEAD>", "dirty": true}`. Selecting it creates a *derived stack* that overrides one entry of a known stack. The UI shows which entries differ from the tested stack, but never blocks the choice. This is how a developer keeps "known-good plus my KosmicKrisp branch" without editing manifests.

### 5.6 Privileged operations

The only root-owned file is `/usr/local/share/openxr/1/active_runtime.json`, and its symlink already points at the user's prefix. Normally, switching Monado versions only changes the target of the user-owned pointer, so no privileges are needed. Changing the system registration to a different runtime is an explicit action, done through a one-shot `SMAppService` helper or an `osascript … with administrator privileges` prompt. It is never automatic.

### 5.7 Building from source

Source builds run the repository's own build entry points, such as Monado's CMake presets and `rebuild-both`, or DXMT's meson. The installer doesn't reimplement them. They run in a temporary worktree pinned to the stack's revision so the developer's checkout is never touched. Each build records a manifest like Monado's `local-install-*.json`: commit, architecture, SHA-256 of each binary, and the backup path.

## 6. Applications and the guest-app framework boundary

The Alyx and Monado pacing work has moved the guest-app framework into its own repository, `~/Code/threshold-runtime` (private, NikNakk/threshold-runtime, MIT): the Linux guest layer (`linux/`) and Android guest layer (`android/`, formerly `alyx-native/quest-host`) on Klepton, per-app fixes, launch and record tools. Launchers find it through `THRESHOLD_RUNTIME`; builds still go to the `THRESHOLD_WORKSPACE` (default `~/Code/alyx-native`). Threshold XR's Quest host detection follows both. Profiles will carry `monado.build_tag`, read from the built binaries (the compiled-in version can lag the source), alongside the commit, branch, build directory and `service: isolated|installed`. Threshold XR should treat that framework as an external provider of applications:

1. **The framework publishes app profiles.** Each profile is a machine-readable file giving the guest type, host binary, Vulkan driver, the Monado settings it needs, launch arguments and exact component revisions. Today `run-alyx-profile` plus `source-revisions.json` hold this information.
2. **The framework provides one launch command** that reports status in a machine-readable form (started, running, exited, crashed), plus the run directory and log paths.
3. **Threshold XR reads the profiles, calls the launch command, shows status**, and manages Monado and its settings. It knows nothing about how the guest loader works.
4. **Bundling.** Threshold XR can ship tested builds of the framework, Monado and KosmicKrisp as one *stack* (§5.1), with each profile recording the exact versions it needs.

This keeps several things separate:

- release cadences
- the MIT credits for VeRantyx and Klepton
- game-specific fixes and data
- xrizer's GPL (it stays a separately built library loaded by applications)

Milestone 1 already follows this: it only *reads* `run-alyx-profile` to show which builds are in use, and launches nothing from the framework.

**Implemented 15 November 2026.** threshold-runtime publishes profiles (`profiles/<id>.json`) and one launch command, `bin/threshold-run`, with a JSON-lines status file (started, stopping, exited with exit code, signal, stopped-by and crashed). Threshold XR lists them with `threshold-run --list --json` (`FrameworkCatalog`), adds them to the Applications list as `.frameworkProfile` targets, blocks launches whose components are missing, and starts them through `FrameworkLauncher`, which maps the status file to a `ProcessExit` (a guest crash is a crash even when threshold-run itself exits normally). Component discovery still reads `run-alyx-profile` for the builds in use. Milestone 2's launcher should be a thin `ApplicationLauncher` protocol, with three implementations:

- framework launch command (Alyx, Quest apps)
- plain `.app` or executable (native OpenXR apps)
- Windows runner (`run-windows-game.zsh <appid>`)

The `alyx-host` and `quest-host` components in Threshold XR then become "provided by framework X" rather than things Threshold XR installs.

## 7. Proposed Milestone 2

1. **Applications.** *Done for native apps:* direct launch through `ApplicationLaunching` (`DirectLauncher` for bundles and executables), followed by `LaunchCoordinator` with status, crash detection and per-launch logs. threshold-runtime applications launch through `FrameworkLauncher` (§6). Still to come: the Windows runner behind the same protocol, and editing the shared `apps.json` catalog.
2. **Live readiness.** Watch launchd job state with a `DispatchSource` process monitor on the service PID, instead of polling every 3 s.
3. **Headset controls.** Add recentre and floor calibration (the `mnd_root_recenter_local_spaces` family) and brightness, gated by the same connection-safety policy.
4. **Component manifest, read-only first.** Add the manifest format, adopt existing installs as `external` releases, and show the "known stack vs. installed" comparison. Install and rollback come after that.
5. **Shared Monado control package.** Extract one libmonado wrapper shared by SwiftXR Shell and ThresholdCore. This is coordinated work in SwiftXR.
6. **Hardware checks.** Exercise live Start/Stop/Restart and reload with the headset attached. Record runtime readiness timings and confirm the idle-exit interaction on hardware.
