# Local Steam bridge build prototype

The prototype builds both Windows halves and the native macOS half of the bridge
without requiring the end user to configure or build Wine. A maintainer exports a
Wine development bundle paired with one exact runtime. The user supplies that
runtime, downloads the pinned Proton sources and compiles the bridge locally.

The command-line implementation is in [`release/steam-bridge`](../release/steam-bridge/).
Threshold XR exposes a guided path through **Components → Set Up Wine…**.

## Build from Threshold XR

Choose between:

- **Packaged Wine:** import prebuilt Wine without `lsteamclient`. No compiler or
  Python is needed for the import. Use it for Windows applications or a separate
  Windows Steam setup; Rosetta is required on Apple Silicon.
- **Wine + native Steam bridge:** start with the same packaged Wine, then compile
  only `lsteamclient` locally to use native macOS Steam with compatible Windows games.

Press **Open GitHub Downloads**, download the `wine-bridge-sdk-prototype` artifact
from the successful run, and extract its ZIP. Choose that extracted folder and
press **Prepare Wine**. The app verifies both archives against its bundled, tested
identities, extracts Wine into its own directory, and saves the matching SDK.

For the bridge option, **Check Setup** checks the tools and runtime. **Build Steam
Bridge** selects the matching runtime, SDK and checksum automatically. Ordinary
setup does not require manually matching paths or copying hashes. **Custom SDK
Build…** retains the advanced folder/archive/HTTPS workflow for other builds.

The result provides **Show Runtime**, **Copy Runtime Path** and **Use for Wine
Detection**. The last button updates Components' Wine detection override. Steam
Play registration and runtime selection are separate: follow **Open Steam Play
Setup Guide** to compose the VR dependencies and compatibility tool. The current
managed preparation tool requires the native Steam bridge; a packaged-only Windows
Steam route needs its own Windows Steam setup. This screen does not present those
two Steam Play routes as already interchangeable.

The sheet shows live output, supports cancellation, and provides the build folder
and completed runtime in Finder. Each command has its own retained log; compiler
logs are under the work directory. Cancelling stops queued compiler work and lets
active compiler processes finish before the builder exits. Download cancellation
also cancels the active network task. Failed/cancelled runs keep their work files.

Outputs are stored in
`~/Library/Application Support/Threshold XR/SteamBridgeBuilds/<run-id>/`.
Imported base Wine and its SDK are stored in
`~/Library/Application Support/Threshold XR/WinePackages/<version>/`.
The operation does not select the runtime for Steam Play or update existing game
prefixes. The bundled builder is copied from the command-line implementation using
`python3 release/steam-bridge/sync-app-resources.py`; `--check` and the Python tests
detect stale copies. `scripts/make-app.zsh` includes the SwiftPM resource bundle in
the signed app.

## End-user dependencies

These compiler dependencies apply to the optional bridge build. Importing packaged
Wine uses the app's native archive reader and requires none of these build tools.

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
the runtime hashes match the packaged result. The clean producer currently requires
an Intel macOS build host, matching CI. For an Intel maintainer run:

```sh
SDK_WORK=/absolute/new/work-directory SDK_VERSION=prototype-1 \
  bash release/steam-bridge/build-wine-sdk.sh
```

The manual [prototype workflow](../.github/workflows/steam-bridge-sdk.yml) performs
this on an Intel macOS runner and uploads the Wine runtime/development bundle as
short-lived Actions artifacts. It does not compile or upload the Steam bridge and
does not publish a GitHub release. Compiler versions are recorded; byte-identical
reproduction across different Apple/Homebrew toolchains is not claimed.

The producer separates `build` and `package` modes. CI caches the completed raw Wine
build before packaging, keyed by source revision, build recipe, compiler/SDK,
installed Homebrew versions, macOS version and work path. Packaging clones the raw
runtime and works on that copy; a failed packaging attempt cannot mutate the cached
input. A completion receipt rejects a cache from a different revision, recipe or
work path.

The first clean producer run is
[43959987641](https://github.com/NikNakk/threshold-xr/actions/runs/43959987641), on the
isolated `codex/steam-bridge-sdk` branch. Wine compiled and installed successfully,
but packaging exposed a shared-library identity bug: an already relocated copy of
`libnettle` was compared with its unchanged external original. The packager now
retains original hashes for copied libraries. Real Mach-O regression tests reproduce
the old failure, pass with the fix, and still reject different libraries with the
same filename. The corrected clean run
[43984029292](https://github.com/NikNakk/threshold-xr/actions/runs/43984029292) succeeded.
`actionlint` validates the workflow expressions before this retry.

The maintainer validator can watch a specific CI commit, download the resulting
artifacts, verify their identities, extract the runtime using the app's guarded
extractor, compile the bridge, stage a runtime and check `wine --version`:

```sh
python3 release/steam-bridge/validate-ci.py --run RUN_ID --commit EXPECTED_COMMIT \
  --work /path/to/new-validation-directory
```

It requires authenticated `gh` plus the normal local build tools, and writes
`validation.json` on success or `failure.json` on error. It never launches Steam or
a game. `--proton-archive FILE` can reuse an already downloaded pinned source tarball.

Remaining integration work includes testing the paired runtime on supported macOS
versions, exposing published SDK versions without a manually entered URL/checksum,
and Steam/game validation of a newly compiled bridge.

## Validation

On 17 November 2026, the clean CI runtime/SDK pair passed the complete maintainer
validator: archive identities, guarded extraction, runtime matching, Win32/Win64 and
native bridge compilation, separate runtime staging and `wine --version` (`wine-11.0`).
The CI SDK targets macOS 14.0; execution was validated on the development Mac, not on
every supported macOS version. Its archive is 61,544,462 bytes and the paired runtime
archive is 224,953,840 bytes. The fresh SDK bridge compile took about 119 seconds with
six jobs; all 346 recorded source dependencies came from the isolated inputs.

CI SDK archive SHA-256:

`1a038c3e593f6a32369a1fb084102d0f60ea25c136458a5880ba92abfddd71f5`

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

The 18-test Python suite covers tampering, runtime mismatches,
archive traversal/links, paths containing spaces, source dependency isolation,
separate output directories, side-by-side staging and bounded retries for transient
GitHub status errors:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s release/steam-bridge/tests -v
```

Eight Swift orchestration tests cover argument boundaries, setup-only operation,
failed builds, concurrent build rejection, cancellation, download checksums and
bundled resources. A real bundled setup check also passed against the locally
exported SDK/runtime. To repeat that optional integration test, supply
`THRESHOLD_TEST_STEAM_SDK` and `THRESHOLD_TEST_STEAM_RUNTIME` when running
`swift test --filter SteamBridgeBuilderTests`.

Seven Wine-kit importer tests pass, including real CI artifact import and handing
the imported runtime/SDK archive to the builder's setup check. They also cover
changed input archives, runtime identity checks, staging cleanup, retaining the SDK
without executing it, reusing existing packages and refusing to overwrite modified
installed files. Supply `THRESHOLD_TEST_WINE_KIT` with the extracted CI artifact
folder to repeat the optional real import test.

The complete Swift suite also passed with normal desktop/GPU access; optional
installed-library/hardware tests were skipped. Ten packager tests pass, including
the two real Mach-O relocation regressions. A packaging-only integration check on
an isolated fixture exported an SDK matching its packaged `ntdll` files and left
the raw fixture inputs unchanged. That fixture is not a complete runnable Wine
installation; the clean CI pair is validated separately.

Compiler depfiles are checked: all non-system source dependencies must come from
the isolated work tree, development bundle or selected Apple SDK. No access to the
original Wine source/build trees is needed by the standalone compiler/link commands.
This does not test Steam login, games, headset use or arbitrary runtime compatibility.

For the separate provenance/licensing assessment, see the
[patch audit](steam-bridge-patch-audit.md). Local compilation does not change upstream
licences. Existing public Steam payload release settings are unchanged.
