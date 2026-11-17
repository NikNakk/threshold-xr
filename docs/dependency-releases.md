# Dependency releases and installation

Implementation of [design §5.8](design.md#58-binary-releases-and-installation-decided-16-november-2026), started 16 November 2026.

Threshold XR installs pinned binary dependencies directly from releases in our public
GitHub forks. Homebrew distributes the desktop app separately. The private
threshold-runtime and alyx-native workspaces remain external application providers.

## What is implemented

- Components → **GitHub Builds…** discovers complete published builds from the seven
  allowlisted forks, including experimental prereleases. It checks at startup and hourly
  while the app is open; **Check for Updates** also checks manually (one-minute cooldown).
  **Install** / **Update** downloads a component without a login or local stack JSON.
  The toolbar shows the number of available updates. Drafts and Actions-only artifacts
  are excluded. Each release must have a valid manifest and all required platform assets;
  declared sizes and GitHub asset SHA-256 digests, when available, must agree.
- Discovery pins the manifest SHA-256, which installation checks again before extraction.
  Installed manifests identify versions; newer build dates trigger Update, older remote
  builds never downgrade automatically, and changed manifests for an existing version
  are blocked. Failed checks remain visible and preserve the last known build, with
  installation disabled until a successful recheck. A component without a complete release is shown as
  unavailable, rather than being presented as an up-to-date installation.
- Single-component installs keep provenance beside the installed files without creating
  a launch-stack receipt. Installation and activation are separate: it does not restart
  Monado or change service, Steam or profile settings. The existing pinned-stack import
  remains available for reviewed compatible combinations.

- `ThresholdCore/Releases` decodes `threshold-xr/stack-1` and `threshold-xr/release-1`.
  The public components plus the legacy private integration repository are explicitly allowed; unknown components, path-like IDs,
  duplicate pins/platforms, malformed checksums and mismatched release identities fail.
- Components → **Install Stack…** imports a local stack JSON and downloads its pinned
  release manifests with URLSession. Every manifest must match the stack's SHA-256
  before any archive is downloaded. Every archive must match its declared size and
  SHA-256 before extraction. Downloads enforce size limits and require HTTPS success.
- Archives extract through macOS's libarchive, with bounded expanded size, one root
  directory, relative symlinks confined to the artifact and no hard links, devices,
  traversal, absolute paths, or writes through symlinks. The app needs no Python,
  Homebrew or command-line archive tool to install releases.
- Versions go to `~/Library/Application Support/Threshold XR/Components/<component>/<version>/<platform>/`.
  Components are staged alongside the destination and renamed into place. Each keeps
  its original `threshold-release.json`. Existing directories are never overwritten;
  a previously installed version can be shared by stacks only when its saved manifest
  exactly matches the requested manifest. Existing manual installations remain untouched.
- A completed stack receipt is written atomically at `Components/Stacks/<id>/stack.json`.
  If a later component fails, already verified component versions remain reusable,
  staging is removed, and no completed stack is recorded. An exclusive file lock
  prevents two Threshold XR processes installing concurrently.
- Monado requires both architectures in one release, with service/wine-client roles.
  Before accepting a new installation, the installer checks that both the service and
  x86_64 runtime library embed the declared build tag.
- `release/` contains the fork workflow generator, isolated build recipes, relocatable
  archive packager, manifest writer, stack pinning tool and safe branch publisher.
  [rollout.json](../release/rollout.json) records published branch commits.

**Installation currently makes verified versioned files available; it does not activate
an XR stack.** Existing discovery, profiles and service configuration continue to select
the running components. The Installed Releases toolbar button opens the managed folder.
Updates are detected automatically but installed only by a click. There is no automatic
service restart, system OpenXR registration change
or rollback UI. The Launch Stack menu now selects managed client paths for native
profiles. A separate local tool prepares a private Wine overlay from explicitly
supplied external Steam bridge components.

## Fork workflows

The six generated dependency workflows come from [release/forks.json](../release/forks.json). The public `threshold-wine-xr` component owns its separate paired-build workflow; do not overwrite it with the generic fork generator. The old `macos-wine-xr` component remains readable for existing private stacks but is not offered in the default public build catalogue.
Each fork receives `.github/workflows/threshold-release.yml` and
`scripts/threshold-release/{build.sh,package.py}` on `codex/threshold-releases`.
Integration branches are not moved by the publisher.

| Component | Fork | Base branch | Artifacts |
| --- | --- | --- | --- |
| monado | NikNakk/monado | macos-upstream-clean | arm64 service prefix + x86_64 client |
| kosmickrisp | NikNakk/mesa | integration/native-alyx-20261115 | arm64 Vulkan driver and ICD |
| xrizer | NikNakk/xrizer | macos-native | arm64 library + Windows x64 OpenVR DLLs |
| klepton | NikNakk/Klepton | macos-native | arm64 klepton-ld translator |
| dxmt | NikNakk/dxmt | macos-xr-native-sharing | x86_64 Unix modules + Windows x64 DLLs |
| wine | NikNakk/wine-crossover | crossover-26.3.0 | x86_64-host WoW64 runtime |
| threshold-wine-xr | NikNakk/threshold-wine-xr | main | paired macOS x86_64 bridge + Windows x64 bridge/loader |

Successful pushes to `codex/threshold-releases` now publish experimental prereleases
named `threshold-ci-<commit12>`. Tags and manual dispatches can also supply a version.
A complete release is uploaded as a draft before publication, so clients cannot discover
an upload in progress. Failed or cancelled builds do not publish. The existing
`macos-wine-xr` public binary hold remains in place. The GitHub UI may only list workflows
present on the default branch. These workflows currently track the review branches;
merging them into integration branches needs a corresponding trigger change.

Builds use macOS arm64 and Intel runners, with MinGW for Windows outputs. They never
install a service or initialize a user's Wine prefix. LLVM/Wine SDK inputs used by
DXMT and source inputs used by the bridge are recorded in `build-inputs.txt` inside
the artifact. These transitive SDK downloads are recorded, not yet locked by a
centrally maintained build-input manifest.

The packager recursively bundles linked non-system dylibs, changes their references
to `@loader_path`, removes absolute rpaths, rewrites runtime/ICD library paths, checks
architecture, and signs modified Mach-O files ad hoc. Unresolved dependencies and
external framework bundles fail packaging. It does not automatically discover
libraries loaded only by a computed `dlopen` name; Wine's known dynamic dependencies
are explicitly staged by its recipe. Developer ID signing and notarization remain
future work. The workflow attests the archives and release manifest using GitHub's
[artifact attestation action](https://github.com/actions/attest).

A release is published only after every platform finishes, matching Monado build tags
are checked, and the combined manifest's archive hashes are rechecked. Existing
releases and conflicting tag commits are refused, rather than replaced. Review-branch
CI and the first end-to-end releases still need to establish each recipe's correctness;
local syntax checks are not evidence that these dependency builds succeeded.

## Maintainer procedure

Regenerate payloads after editing the common scripts:

```sh
python3 release/generate-forks.py
python3 release/publish-forks.py          # inspect live bases and proposed branches
python3 release/publish-forks.py --publish
```

The publisher creates new branches, records exact commits, and refuses to overwrite
an existing branch not recorded by this checkout. It is intended for the initial
rollout; further changes should be reviewed and committed to those branches normally.
Mesa's generated payload omits generated comments and docstrings, and its commit uses
the user's supplied instruction with the required `Generated-by: LLM` trailer.

After review-branch CI passes, choose a unique version and push its tag at the reviewed
workflow commit. Monado's build tag comes from `git describe --exclude 'threshold-*'`;
the release version can equal that identity, but must remain a safe filename token.
The x86_64 service client is built from the same source commit as the arm64 service.

Download the published `threshold-release.json` for each component into separate local
folders, then pin their exact bytes:

```sh
python3 release/make-stack.py --id psvr2-experimental-2026-11 \
  --output psvr2-experimental-2026-11.json \
  downloaded/monado/threshold-release.json downloaded/xrizer/threshold-release.json
```

Include all seven manifests to create the full dependency stack, or a subset when
installing a component independently. `--channel stable` also requires `--evidence`
pointing to recorded hardware results. Publish reviewed stack JSON in threshold-xr,
then import it in Components → Install Stack…. The local import is the current trust
boundary: hashes pin content but are not a detached signature or a trusted catalog.
Only import a stack obtained from a trusted maintainer.

## Threshold Runtime and Steam Play integration

Implementation update: both integrations now have code and stand-in tests on
`codex/managed-stacks` in their respective repositories; the tested changes are also
applied to the existing local checkouts. Public Steam release binaries are held and
Steamworks-derived components are externally supplied. See the
[packaging boundary and current validation](steam-play-packaging.md).


The seven public dependency releases are the binary foundation, not a complete
user-installable application stack. Two application paths must be included in the
acceptance criteria before this rollout is considered usable.

### Native Linux and Android applications

Threshold Runtime owns the hosts, application profiles, preparation and launch/status
contract. Threshold XR already discovers its profiles through
`threshold-run --list --json` and launches through `FrameworkLauncher`. The private
source repository and local application data remain external providers under the
current design; this release rollout does not change repository visibility or publish
its hosts or game data.

The selected dependency stack now feeds the existing Threshold Runtime
component-override interface for both listing and launching. Without a selection, profiles retain their workspace paths. With a selection,
managed xrizer and KosmicKrisp paths replace them; packaged loaders are preferred when
present, while native hosts, ANGLE and other adopted components remain external. Selecting installed public
artifacts must supply those paths explicitly, record exact versions/build tags in the
run report, and check host/runtime compatibility before launch. Adopting the local
host build is the initial path; private binary distribution, if introduced, needs its
own authenticated download and provenance contract. A standalone `klepton-ld` release
does not replace the Klepton runtime code compiled into the Linux and Android hosts.
The OpenXR loader and Android graphics dependencies such as ANGLE also need explicit
provisioning; they are not supplied by the seven release recipes as a complete native
application runtime.

Acceptance: list and dry-run profiles with managed dependency paths, then exercise
launch/status/stop/error reporting for the Linux and Android routes. Record hardware
results separately. Prepared game trees, APKs, saves and user data remain separate from
component installation and rollback.

### Steam Play and the Windows compatibility runtime

The current production route is Steam Play's compatibility tool → game runner → WoW64
Wine with DXMT and lsteamclient, using in-process wineopenxr for OpenXR and xrizer for
OpenVR. The revised release recipe builds the real Steam Play launcher payload and the Windows
OpenXR loader. The locally prepared runtime supplies the production bridge modules,
with their external provenance recorded. Public binary uploads are held pending the
licensing review; these are not yet validated production releases.

The integration checklist below also identifies work that still needs real-game and
licensing validation; local composition, prebuilt installation and the threshold-run
Alyx adapter are now implemented:

1. Build the in-process wineopenxr modules and both supported architectures of
   lsteamclient against the exact released Wine source/build. Preserve and verify the
   required ntdll redirect. Keep third-party payload provenance and distribution
   boundaries explicit; the lsteamclient build script currently fetches pinned Proton
   sources rather than storing them in this repository.
2. Compose a private, versioned compatibility runtime containing Wine, DXMT, those
   bridge modules, the matching Monado x86_64 client, xrizer and required loaders.
   Replace assumptions about `~/Code`, `build-in-process` and the rig wrapper under
   `~/Windows` with an explicit runtime/configuration contract. An update must not
   overlay the existing `runtime-unified` or rewrite game prefixes.
3. Install the complete Steam Play payload: the launcher, compat gate and its helper
   tools, compatibility-tool manifests, setup-script support and game-mapping helpers.
   Bind its runner to the selected managed runtime. Preserve the existing in-memory
   gate behavior and per-game mappings; do not edit Valve's application bundle or
   automatically map every macOS title to a Windows depot.
4. Route native Alyx's `MWXR_ALYX=native` option through the same Threshold Runtime
   profile/stack selection used by Threshold XR. Its current Steam adapter invokes the
   older `alyx-native/run-alyx` entry point. Preserve argument filtering, process-group
   shutdown and Steam's running/stop tracking when migrating it to `threshold-run`.
5. Test Steam tool registration and mappings, install-script handling, 32/64-bit Wine
   launches and Steamworks connectivity, then OpenXR/OpenVR launches and native Alyx's
   alternate route. Confirm stop propagation, logs, prefix/save preservation and
   switching back to a previous compatibility runtime. Tests using stand-in games or
   launchers must be distinguished from real Steam and headset evidence.

The release work is complete only when the native application path and Steam Play
path can consume the installed stack. Green archive-build jobs alone do not establish
that. Prioritize auditing and completing these payloads before publishing a stack as
ready for users.

## Remaining stages

1. Complete the Threshold Runtime and production Steam Play payload audit above,
   update the recipes to cover the actual launch paths, and finish green review-branch
   builds in all seven forks. Fix any runner/build or
   relocation issues they reveal. No production release has been validated yet.
2. Produce first experimental releases, download a complete stack to an empty managed
   root, and test relocated libraries and executable entry points. Keep build, runtime
   and physical-headset evidence separate.
3. Complete component version comparison around the implemented native launch-stack
   selection, including registration of
   existing installs as external versions. Verify existing installed bytes before
   treating reused component directories as intact; currently reuse checks the saved
   manifest, not a full installed-file inventory.
4. Add explicit activation and rollback: stop only with user intent, install Monado
   using its own environment-preserving helper, select matching runtime/client
   manifests, compose DXMT into a private versioned Wine runtime, and configure the
   bridge/Steam Play runners for that runtime. Move one selected-stack pointer only
   after preparation succeeds; restore the previous selection on failure. Do not
   rewrite existing Wine runtimes or developer launch profiles.
5. Validate hardware and application compatibility, record evidence, and then promote
   a pinned stack to stable. Homebrew cask distribution of Threshold XR is a separate
   delivery task from dependency release installation.

## Validation

The desktop app builds. All 98 existing ThresholdCore Swift Testing tests and eight
new XCTest installer tests and three launch-stack tests pass with local socket access. The initial sandbox run
blocked existing socket-binding tests; the run with socket access passed.
Eight Python packaging tests pass. All seven generated workflow YAML files and their
embedded Bash blocks parse, and the build recipe passes `bash -n`.
These checks do not substitute for the fork CI builds or a published-release install.

All seven workflow branches have been published. Five initial release-workflow runs
were observed queued; Mesa and macos-wine-xr were dispatched manually after their
branch push started only their older workflows. Those two manual runs may publish
experimental preview releases if all checks pass. Refresh the recorded CI state with
`python3 release/check-ci.py`; it prints a direct run link for each fork.

## Release failure investigation, 16 November

Mesa's first release job failed because the recipe omitted LLVM. The corrected recipe
installs LLVM, SPIRV-LLVM Translator and SPIRV-Tools and exposes their tool/pkg-config
paths. Windows xrizer failed because bindgen could not find C++ headers during a
macOS-host cross-build; it now uses ubuntu-24.04 and the fork's Linux MinGW build route.

The cancelled Monado, Klepton and macos-wine-xr arm64 jobs had no build logs: GitHub's
annotations say the jobs were not acquired by a hosted runner, with arm64 capacity
notices. A DXMT job also failed to acquire a runner. New ARM jobs target macos-26;
this changes the runner/SDK but is not a guarantee of queue availability. Running
Wine/DXMT jobs were not cancelled or restarted by this fix. Updated review-branch
commits and current run links are in `release/rollout.json`.

The corrected [Mesa release build](https://github.com/NikNakk/mesa/actions/runs/43942012880)
passed. Other updated runs remain queued at the latest status check; Wine/DXMT were
still in progress. See the recorded links rather than assuming queued jobs passed.

Follow-up local checks also passed: 16 threshold-runtime launch tests, two run-report
tests, seven managed Steam Play tests, and 12 existing Steam Play mapping/settings
tests. A fresh public launcher package compiled; a side-by-side app assembled from it
passed `codesign --verify --deep --strict` using fixture runtime files, without starting
Steam or creating Wine prefixes. The existing local threshold-runtime catalog still
loads all four profiles. Real games, Steam sign-in and headset use remain untested.

## GitHub catalogue validation (17 November 2026)

The successful Mesa run 43942012880 was promoted without rebuilding to the preview
`threshold-ci-6b9c88ae908b`, with its original archive checksum and source commit.
The native app catalogue and installer were exercised against that public release in
an isolated temporary directory. Other components appear as unavailable until their
complete fork builds succeed and publish. This distinction is intentional: a green
build for only one architecture does not make a multi-platform component installable.

The common Wine packager fix for duplicate references to already relocated dylibs is
included in the fork update. DXMT's downloaded LLVM/Wine work directory is moved
outside the source tree to satisfy Meson's include-directory rules. Neither local
checks nor a queued rerun establish that those builds now pass.

## Public and private Windows XR selection

The public bridge component is `threshold-wine-xr` from `NikNakk/threshold-wine-xr`, with `macos-x86_64` and `windows-x86_64` archives. Its own release workflow publishes a `threshold-xr/release-1` manifest and pinned dependency source/provenance. The desktop app validates and installs it like other independent components; Wine, DXMT, xrizer and Monado remain separate.

Wine setup defaults to Windows Steam. After composing a local public runtime with the public bridge's preparation tool, **Components → Launch Stack → Select Windows XR Profile…** verifies its inventory and stores the exact prepared profile. Public profiles use `windows_xr.integration: windows-steam`, private profiles use `steam_play.integration: native-steam`, and legacy `steam_play` profiles retain their private meaning. Both modes keep their own prefixes and runtime directories; mixed profiles are rejected. Profile selection does not start/stop services, copy game data or alter the existing private installation. See the [public managed-profile guide](https://github.com/NikNakk/threshold-wine-xr/blob/main/docs/managed-profiles.md).
