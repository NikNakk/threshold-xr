# Local Steam bridge build prototype

The prototype builds both Windows halves and the native macOS half of the bridge
without requiring the end user to configure or build Wine. A maintainer exports a
Wine development bundle paired with one exact runtime. The user supplies that
runtime, downloads the pinned Proton sources and compiles the bridge locally.

The command-line implementation is in [`release/steam-bridge`](../release/steam-bridge/).
Threshold XR also exposes it through **Components → Build Steam Bridge…**.

## Build from Threshold XR

Choose an extracted SDK folder, an SDK archive, or an HTTPS archive download. For
an archive/download, enter its trusted SHA-256 checksum. Choose the paired Wine
runtime and press **Check Setup** to validate tools and runtime identity. Then
**Build Local Runtime** compiles the bridge and stages a separate runtime.

The sheet shows live output, supports cancellation, and provides the build folder
and completed runtime in Finder. Each command has its own retained log; compiler
logs are under the work directory. Cancelling stops queued compiler work and lets
active compiler processes finish before the builder exits. Download cancellation
also cancels the active network task. Failed/cancelled runs keep their work files.

Outputs are stored in
`~/Library/Application Support/Threshold XR/SteamBridgeBuilds/<run-id>/`.
The operation does not select the runtime for Steam Play or update existing game
prefixes. The bundled builder is copied from the command-line implementation using
`python3 release/steam-bridge/sync-app-resources.py`; `--check` and the Python tests
detect stale copies. `scripts/make-app.zsh` includes the SwiftPM resource bundle in
the signed app.

## End-user dependencies

- Apple Command Line Tools, providing Apple Clang, the macOS SDK and signing tools.
- Python 3.9 or newer.
- MinGW-w64, providing both `x86_64-w64-mingw32-gcc` and `i686-w64-mingw32-gcc`.
  With Homebrew installed: `brew install mingw-w64`.
- Rosetta on Apple Silicon, because the Wine tools and native bridge are x86_64.
- The paired Wine runtime and development bundle.
- Internet access for the first Proton download, or a matching offline source tree
  or tarball.

The user does not need Bison, CMake, a Wine source checkout or a configured Wine
build directory. Steam, SteamCMD and game data are not needed to compile. Running
games still requires the appropriate Steam client setup and game entitlement.

The bundle records its minimum macOS version. The builder checks it and sets the
bridge's deployment target accordingly, rather than silently targeting whichever
newer SDK happens to be installed. The first local bundle uses existing Wine tools
targeting macOS 27.0; it is not a macOS 14 compatibility test. The clean CI producer
uses the release recipe's macOS 14 deployment target.

## Build with an extracted development bundle

From the Threshold XR checkout, with a matching runtime in `RUNTIME`:

```sh
python3 release/steam-bridge/bridge.py doctor --sdk /path/to/sdk
python3 release/steam-bridge/bridge.py build \
  --sdk /path/to/sdk --runtime /path/to/RUNTIME \
  --work /path/to/new-build-directory --output /path/to/new-bridge-directory
```

The work and output directories must be new and separate from each other, the SDK
and runtime. Paths containing spaces are supported. `--jobs N` controls parallelism
(default: at most six jobs). Build logs and compiler dependency files remain in the
work directory. A failed build leaves its work directory for diagnosis; retry with
a new work directory.

The normal build downloads the exact Proton commit in
[`inputs.json`](../release/steam-bridge/inputs.json), verifies the extracted tree,
applies the hash-checked macOS adaptation patch, and compiles 44 C sources per
Windows architecture plus 219 native C++ sources. `--source-tree DIR` accepts a
pristine offline `lsteamclient` tree; `--source-archive FILE` accepts the full pinned
Proton GitHub tarball. Both paths are checked against the same extracted-tree digest.

The result includes explicit `i386-windows` and `x86_64-windows` directories,
`lsteamclient.so`, `mwxr-steam.exe`, upstream/launcher licence files and `build.json`
with input/output hashes and compiler versions. The native library is ad hoc signed.

The runtime's three `ntdll` files must match the bundle's recorded hashes. This is
deliberately conservative: even signing changes can require a newly paired bundle.
The builder never updates the supplied runtime, a game prefix or a Steam installation.

## Stage a separate runtime

```sh
python3 release/steam-bridge/bridge.py stage-runtime \
  --sdk /path/to/sdk --runtime /path/to/RUNTIME \
  --bridge /path/to/new-bridge-directory --output /path/to/new-runtime-directory
```

This verifies the bridge's recorded hashes and SDK identity, clones the supplied
runtime into a new destination (using an APFS clone where available), overlays the
bridge and launcher, and preserves notices under `share/threshold-steam-bridge`.
It leaves the original runtime and every existing prefix untouched. The resulting
runtime can be supplied to the existing local Steam Play preparation flow. This
command does not initialise a prefix, switch the active runtime, launch Steam or
run a game.

## Export and transport a development bundle

For maintainers with a clean, committed Wine source checkout and its existing WoW64
build and runtime:

```sh
python3 release/steam-bridge/bridge.py export-sdk \
  --wine-source /path/to/wine-source --wine-build /path/to/wine-build \
  --runtime /path/to/paired-runtime --version VERSION --output /path/to/new-sdk
python3 release/steam-bridge/bridge.py archive-sdk \
  --sdk /path/to/new-sdk --output /path/to/wine-bridge-sdk.tar.gz
```

The exporter requires the Steam loader redirects in the source/runtime, both PE
architectures, and a Wine build configured against the supplied source directory.
It includes source/generated headers, `winebuild`, `winegcc`, six Windows libraries
per architecture, a native `ntdll` link input, Wine licence/author notices, configure
arguments and a complete Git source archive. It never copies `dlls/lsteamclient`.
An SDK exported from an existing build records those supplied artifacts; it does not
independently prove they were compiled from the recorded revision.

The archive command creates a `.sha256` sidecar. Obtain that expected checksum from
the trusted producer, then extract using:

```sh
python3 release/steam-bridge/bridge.py unpack-sdk \
  --archive /path/to/wine-bridge-sdk.tar.gz --sha256 EXPECTED_SHA256 \
  --output /path/to/new-sdk
```

Extraction checks the archive hash, rejects links and escaping paths, verifies every
manifest entry, preserves executable permissions, and refuses existing destinations.
Checksums verify identity against the supplied expected value; they are not signatures.

## Clean producer and remaining integration

[`build-wine-sdk.sh`](../release/steam-bridge/build-wine-sdk.sh) fetches an exact Wine
revision, uses the existing managed Wine release recipe, packages/relocates the
runtime, then exports the matching SDK. Export happens after signing/relocation so
the runtime hashes match the packaged result. For a local maintainer run:

```sh
SDK_WORK=/absolute/new/work-directory SDK_VERSION=prototype-1 \
  bash release/steam-bridge/build-wine-sdk.sh
```

The manual [prototype workflow](../.github/workflows/steam-bridge-sdk.yml) performs
this on an Intel macOS runner and uploads the Wine runtime/development bundle as
short-lived Actions artifacts. It does not compile or upload the Steam bridge and
does not publish a GitHub release. Compiler versions are recorded; byte-identical reproduction across
different Apple/Homebrew toolchains is not claimed.

The first clean producer run is
[43959987641](https://github.com/NikNakk/threshold-xr/actions/runs/43959987641), on the
isolated `codex/steam-bridge-sdk` branch. Results are recorded below when validated.
Remaining integration work includes testing the paired runtime on supported macOS
versions, exposing published SDK versions without a manually entered URL/checksum,
and Steam/game validation of a newly compiled bridge.

## Validation

The local prototype successfully compiled both PE architectures and the x86_64
macOS bridge from an exported SDK. Archive extraction and the pinned upstream
download were also exercised. The final six-job compile took about 56 seconds on
the development Mac (excluding download and bundle extraction). The SDK archive is
61,554,818 bytes, about 59 MiB, including the complete compressed Wine source.
Compiler depfiles listed 346 unique source dependencies, all within the isolated
inputs. A new local runtime was staged successfully and the original runtime's
three recorded `ntdll` hashes still matched afterwards. No Steam/game launch was
performed. These measurements describe this machine and toolchain, not a general
performance guarantee.

The 15-test Python suite covers tampering, runtime mismatches,
archive traversal/links, paths containing spaces, source dependency isolation,
separate output directories and side-by-side staging:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s release/steam-bridge/tests -v
```

Eight Swift orchestration tests cover argument boundaries, setup-only operation,
failed builds, concurrent build rejection, cancellation, download checksums and
bundled resources. A real bundled setup check also passed against the locally
exported SDK/runtime. To repeat that optional integration test, supply
`THRESHOLD_TEST_STEAM_SDK` and `THRESHOLD_TEST_STEAM_RUNTIME` when running
`swift test --filter SteamBridgeBuilderTests`.

Compiler depfiles are checked: all non-system source dependencies must come from
the isolated work tree, development bundle or selected Apple SDK. No access to the
original Wine source/build trees is needed by the standalone compiler/link commands.
This does not test Steam login, games, headset use or arbitrary runtime compatibility.

For the separate provenance/licensing assessment, see the
[patch audit](steam-bridge-patch-audit.md). Local compilation does not change upstream
licences. Existing public Steam payload release settings are unchanged.
