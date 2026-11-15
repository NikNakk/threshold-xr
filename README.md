# Threshold XR

Threshold XR is a native macOS app for managing an OpenXR setup on Apple Silicon Macs: the Monado runtime, xrizer, DXMT, KosmicKrisp, Wine, the native Alyx and Quest hosts, and Threshold Home.

It is an ordinary desktop app. It opens and works with no headset connected. It manages Monado through Monado's existing per-user LaunchAgent. Quitting Threshold XR leaves Monado running, and OpenXR applications started from Finder, the Dock or a terminal keep working without it.

| Name | What it is |
| --- | --- |
| **Threshold XR** | This desktop app: installer (planned), configuration manager and launcher. |
| **Threshold Home** | The optional immersive environment in the headset. Its source is in [`ThresholdHome/`](ThresholdHome/README.md) (imported from SwiftXR Shell with its history); it is still built and installed as `SwiftXR Shell.app`. |
| **Threshold Agent** | An optional background component. It is not needed yet; see [the design document](docs/design.md#threshold-agent). |
| **SwiftXR** | The existing Swift XR framework. This project does not depend on it or change it. |
| **Monado** | The OpenXR runtime. It stays usable on its own. |

## Milestone 1 features

- **Home**: four separate status checks, each with its own card:
  - Installation
  - Service
  - Runtime (ready means listening for applications)
  - Headset

  Also on Home: Start, Stop and Restart for Monado's LaunchAgent (plus Load when it is unloaded), the system and login-session OpenXR registration (read-only), and a button to open Threshold Home.
- **Components**: detects each component and shows its version, location, the files it found, its source checkout (branch and commit) and how each path was found. You can override the detection path for any component.
- **Settings**: 11 real Monado options and 4 app preferences. Each setting records its type, valid values, default, owner, whether it applies live or needs a service reload, and whether it is advanced or developer-only.
- **Monado's last run**: Home shows problems from the latest run in Monado's service log (for example a compositor that could not set the display's refresh rate, or a USB interface it could not claim), and a launch notes any problem Monado logged while it ran.
- **Headset**: PS VR2 USB presence, plus devices and clients reported by Monado when it is safe to ask.
- **Diagnostics**: the service's log, the app's activity log, the full OpenXR runtime search order, the client-environment variables, the environment of the loaded service, and a copyable report.
- **Applications (direct launch)**: starts apps from the shared application list (Threshold Home's `apps.json`, threshold-runtime's applications and macOS Steam's installed VR games, the same list Home shows) straight into the headset, without Threshold Home.
  - `.app` bundles open through Launch Services; executables and scripts run with their output logged to `~/Library/Logs/Threshold XR/Launches/<app>/`.
  - Each launch is followed through *Starting*, *Running*, *Connected* (a new Monado connection appears), *In headset* (Monado reports the matching client's session as visible or active), then *Ended*, *Crashed* (crash signal or a new macOS crash report) or *Failed*.
  - Stop sends a normal quit and forces it after 3 s.
  - A preflight check blocks missing or non-executable targets and duplicate launches, and warns when Monado cannot start on demand or is not the session runtime.
  - Threshold XR never sets Monado's primary or focused client: if Threshold Home is running, its existing hand-over does that.
  - Launched apps keep running if Threshold XR quits.

## Build and run

You need Apple Silicon, macOS 14 or later, and Xcode 16 or later (Swift 6). There are no third-party dependencies.

```bash
swift build
swift test
swift run threshold-xr
```

The package also builds Threshold Home (`swiftxr-shell`). Threshold Home needs the Khronos OpenXR loader in `/usr/local/lib` and SwiftXR: the local checkout at `SWIFTXR_PATH` (default `~/Code/SwiftXR`) when present, otherwise SwiftXR's `swiftxr-video-player-poc` branch on GitHub. Threshold XR itself needs neither; build it alone with `swift build --product threshold-xr`.

To install Threshold Home (as `SwiftXR Shell.app` in `/Applications`, or a folder you name):

```bash
ThresholdHome/scripts/make-app.zsh
```

To build `Threshold XR.app` (into `./build` by default):

```bash
scripts/make-app.zsh
```

```bash
open "build/Threshold XR.app"
```

To build it straight into `/Applications` instead:

```bash
scripts/make-app.zsh /Applications
```

The script signs with your single Apple Development identity if you have one, otherwise ad hoc. Set `SIGN_IDENTITY` or `BUNDLE_ID` to override either. It follows the same conventions as SwiftXR Shell's `scripts/make-app.zsh`.

Threshold XR and Threshold Home share SwiftXR Shell's headset artwork (`Resources/AppIcon.png` and `ThresholdHome/Resources/AppIcon.png`); `make-app.zsh` turns the 1024px PNG into the app's `.icns`.

To render every screen to PNG without a display session or Screen Recording permission (a developer aid):

```bash
.build/debug/threshold-xr --snapshot /tmp/threshold-shots --appearance dark
```

## Architecture

```text
Threshold XR.app (SwiftUI)       Sources/ThresholdXR
  AppModel: schedules work, publishes state; no business logic
        │
ThresholdCore (library)          Sources/ThresholdCore
  Launch/       launch targets, preflight, launchers (bundle/executable),
                launch coordinator, crash-report finder
  Monado/       LaunchAgent model + writer, launchctl control, OpenXR
                registration, installation discovery, libproc socket
                inspection, read-only libmonado (dlopen), status aggregation
  Components/   component models, read-only discovery, Alyx play-profile reader
  Settings/     descriptors with metadata, catalog, stores
  Headset/      passive IOKit USB enumeration
  Home/         Threshold Home (SwiftXR Shell) apps.json reader
  Support/      command runner, discovery context, file probes, git reader
        │
Existing infrastructure, used as it is:
  ~/Library/LaunchAgents/org.freedesktop.monado.service.plist   (launchd, on-demand Mach service)
  ~/Library/LaunchAgents/org.freedesktop.monado.client-environment.plist
  <prefix>/bin/monado-service, lib/libmonado.dylib, share/openxr/1/openxr_monado.json
  /usr/local/share/openxr/1/active_runtime.json                 (system registration, read-only)
```

ThresholdCore has no UI code and no link-time XR dependencies, so Threshold Home or an agent can reuse it later. External effects all go through injectable protocols: `CommandRunning`, `ProcessSocketInspecting`, `USBDeviceEnumerating` and `RuntimeQuerying`. That keeps discovery and service control testable without launchd or a headset.

### Key decisions (details in [docs/design.md](docs/design.md))

1. **The LaunchAgent is the source of truth for Monado.** Discovery takes the installed prefix from the agent's program path, with no fixed development paths. Monado settings stay in the agent's `EnvironmentVariables`, which `monado-service-xpc-control install` and Monado's local-preferences script already preserve. Threshold XR keeps no copy of them. Writes change only the edited variables, keep every other key, and save a timestamped backup to `~/Library/Application Support/Threshold XR/Backups/LaunchAgents/` first.
2. **Readiness is checked passively.** If libmonado connects while Monado's socket is missing, launchd starts the service through XPC and it claims the headset. And whenever a client disconnects and leaves zero clients, the service's idle-exit timer starts (`ipc_server_per_client_thread.c`). So a naive probe would either start Monado or stop it. Instead, Threshold XR reads `monado-service`'s file table with `libproc` to see whether it is listening on `~/Library/Caches/monado/monado_comp_ipc` and how many connections it has. It only connects through libmonado when another client is already connected, or when you ask and confirm the warning.
3. **Service control uses `launchctl` in the user domain only**, so it never needs admin rights:
   - Start: `kickstart`
   - Stop: `kill SIGTERM`, then wait; Force Stop (SIGKILL) is offered only if that times out
   - Restart: `kickstart -k`
   - Load: `bootstrap`, retried on EIO the same way Monado's helper does it
   - Reload: `bootout` then `bootstrap`

   Starting asks for confirmation, because a manually started service keeps the headset until it is stopped.
4. **The OpenXR registration is never changed.** It is shown with its symlink target, the session `XR_RUNTIME_JSON` and the loader's search order.
5. **The installed binaries define what is real.** The Monado build tag is read from `monado-service`. Each setting's variable is checked against the binary's strings. Wine's x86_64 Monado client is compared with the service's build tag, because a mismatch makes Windows XR applications fail to connect.
6. **Development builds come from their own records.** KosmicKrisp, the native xrizer library and the Alyx host are taken from `alyx-native/run-alyx-profile`'s `CURRENT_PLAY` list, not guessed from the many builds in the workspace.

## Tests

Threshold Home's own 61 tests run in the same `swift test`; see [its README](ThresholdHome/README.md) for its hardware tests.


`swift test` runs 76 tests in 16 suites:

- launchctl output parsing and service actions (fake runner): start, restart, stop with wait and timeout, not-loaded errors, load retry, reload order
- the runtime-query safety policy and status aggregation (installed, service, runtime and headset kept separate)
- installation discovery from a LaunchAgent, overrides, and socket location
- OpenXR registration through symlinks, and session overrides
- component discovery in a temporary home: play-profile builds, DXMT inside Wine, KosmicKrisp with a missing library, the Wine/Monado tag mismatch warning
- real `libproc` inspection of a listening and connected Unix socket
- setting validation and encoding, LaunchAgent writes (backup, preserved keys, rejected invalid values), app preferences
- direct launch with real child processes: logged output and environment, clean exit, non-zero exit, crash signal, crash report, stop, forced stop of a process that ignores SIGTERM, start failure, duplicate launches, and Connected/In headset tracking from Monado status

## Live service check (7 November 2026)

With your approval, Start, Restart and Stop were run through `MonadoController` against the installed service, with no headset attached:

| Step | Result |
| --- | --- |
| Before | Service idle, runtime stopped; no connection attempted |
| Start (`kickstart`) | Running (pid 22791). Runtime *starting* until about 1.5 s, then *ready* (listening on `~/Library/Caches/monado/monado_comp_ipc`, 0 connections) |
| Automatic query | Skipped as designed: no clients, and idle exit is on |
| Restart (`kickstart -k`) | New pid 22818, ready within 2 s |
| Stop (`kill SIGTERM` + wait) | Exited cleanly (`Server exiting: '0'`); launchd reports `not running` |
| LaunchAgent plist | Byte-identical before and after (SHA-1 checked) |

The check also found a brief moment while launchd tears the job down when `launchctl print` gives no `state` line. That is now reported as idle, and a test covers it.

## Limitations

- There is no CI yet. Both apps now build from a clean checkout using SwiftXR's `swiftxr-video-player-poc` branch on GitHub (checked with `SWIFTXR_PATH` pointing elsewhere). SwiftXR is private, so CI will need a token that can read it.

- Installing components and editing the app catalog are deferred; see the design document.
- Direct launch was verified on hardware on 7 November 2026 (headset connected, not worn) with Open Brush on Monado `v25.1.0-2488-gb870ce571`: *Running* → *Connected* (on-demand activation) → Open Brush's client identified by name → *In headset* after about 18 s (primary, active, visible, focused) → stopped cleanly, with Monado idling out afterwards. An Alyx launch has not been tried yet.
- Alyx's `play` profile uses the installed Monado service (since alyx-native `3b9cace`), so Alyx launches can reach *Connected*. xrizer reports the host executable's name (`alyx_host`) to Monado, so *In headset* needs the catalog entry's `openXRApplicationName` to be `alyx_host`. Other Alyx profiles (`play-recorded`, comparisons, replays) still start their own temporary Monado and will never show *Connected*.
- The headset check is passive: USB presence (Sony `054C:0CDE`, from Monado's psvr2 driver) plus Monado's head device when a query is safe. The PS VR2 display connection is not checked separately.
- The OpenXR loader does not record its own version, so the OpenXR-SDK checkout's version is shown instead and labelled as such.
