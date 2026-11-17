# Steam Play packaging and distribution boundary

The implementation separates public launcher/dependency packages from a locally
prepared compatibility runtime. This is a risk-reduction design, not a legal finding
that all uses or distributions are permitted.

## Public package

`macos-wine-xr/scripts/package-steam-play.zsh` builds our universal launcher, universal
compat gate, arm64 scanner, scripts and compatibility-tool definitions. It includes the
launcher sources and build recipe under `sources/steam-play`, plus the repository's
licence. It includes no Valve icon, Steam client, game data, SDK tree or lsteamclient.

The Windows artifact now builds Khronos's Windows OpenXR loader, rather than presenting
the older generic RPC thunk as the production Wine integration. That artifact also
needs the applicable Khronos notices and source provenance.

`release/distribution-policy.json` and the packager reject known Steam client and
Steamworks-derived binary names and SDK directories before and after relocation.
This is an explicit exclusion check, not a complete licence audit: renamed files,
embedded code and additional transitive dependencies still require review.

Public macos-wine-xr binary artifact uploads and release publication are disabled in
the generated workflow while the client/SDK terms are reviewed. Source changes and
local build/tests can proceed. The previous preview-release run failed and did not
reach its publish job.

## External Steam bridge

The [local build prototype](steam-bridge-local-build.md) now exports a paired Wine
development bundle and compiles the Steam bridge in a separate work directory.
It can stage a new local runtime without modifying the supplied runtime or prefixes.

The project's pinned Proton lsteamclient tree contains the
[Steamworks SDK licence](https://github.com/ValveSoftware/Proton/blob/bc896217ffcd67f892f952b010f898fe7bd0f0a1/lsteamclient/LICENSE).
Section 1.1 describes local source use for development and object-code distribution
of files provided in `redistributable_bin`. It does not provide an explicit general
redistribution grant for our modified bridge. Section 2.4 also contains restrictions
that need to be considered when assessing this integration. Public GitHub availability
is not itself permission to relicense or redistribute it.

Until appropriate rights are established, the public workflows do not build or
publish lsteamclient. The local preparation tool takes an explicitly supplied,
already working runtime containing it. That tool records external input hashes and
marks build attestation as unverified; it does not fetch SDK sources, assert legal
permission, or turn those files into public release artifacts. Local compilation or
a separate download is not a licensing workaround.

## Open-source obligations

Wine, DXMT and our bridge have LGPL notices; xrizer has GPLv3 notices. For distributed
binaries, assemble the applicable notices and complete corresponding source, including
modifications and build/install scripts. Include the actual bundled dependency closure,
not just the top-level repository's licence. Preserve the applicable replacement and
relinking rights; ad hoc signing and splitting files into downloads do not waive them.
See [LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) and
[GPLv3](https://www.gnu.org/licenses/gpl-3.0.html).

Do not seed a public package by copying an installed CrossOver/GPTK application or
Steam.app. Build identified open-source components from their intended sources, and
inventory every additional file and its distribution terms. The current release
work still needs a complete source/notice inventory for transitive bundled libraries;
`build-inputs.txt` and hashes alone do not satisfy all licence obligations.

## Separate Steam client terms question

The compat gate changes the running Steam client's behavior. Licensing our code under
LGPL does not resolve the applicable Steam agreements. This needs a qualified review
against the [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/)
and any relevant SDK terms, and/or clarification from Valve before public binary
shipping. No tool will contact Valve or anyone else automatically.

## Local operation and validation

Threshold XR's Launch Stack menu exports `threshold-xr/launch-stack-1`. Updated
threshold-runtime uses it for profile listing and launch, keeping native hosts and
ANGLE as adopted external components and refusing mismatched Monado service/client
tags. The private threshold-runtime repository remains private.

The Steam Play preparation tool clones a supplied runtime into a new destination,
overlays the selected DXMT/xrizer, relocates and signs the combined runtime, and records
critical file hashes. Installation of the prebuilt launcher is side by side and binds
its runner to a configuration snapshot. Neither step starts Steam, creates a game
prefix, modifies the supplied runtime, or replaces an existing installation. Actual
game launch can initialize/update the selected persistent prefix as Wine normally does;
runtime rollback is not a promise that a changed prefix can be rolled back.

Native Alyx's managed Steam route calls threshold-run with the same stack. Tests cover
argument filtering, waiting for the framework runner, forwarding Stop, composition,
changed-file checks and paths containing spaces. Actual Steam/game/headset validation
and the distribution questions above remain outstanding. The commands and layout are
in `macos-wine-xr/docs/managed-stacks.md` on `codex/managed-stacks` and
`codex/threshold-releases`.
