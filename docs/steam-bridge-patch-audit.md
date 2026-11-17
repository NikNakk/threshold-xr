# Steam bridge patch provenance audit

Audited 16 November 2026. This is a source and packaging audit, not legal clearance.

## Result

The macOS adaptation patch does not bundle whole Steamworks SDK headers or Valve binaries. However, it reproduces upstream source in diff context and removed lines, and modifies upstream expressions. Describing the repository as containing “no Valve code” is therefore too broad. Downloading the full component at build time does not, by itself, settle permission to use, modify or redistribute that component, its patches or resulting binaries.

The principal unresolved question is the rights applicable to Proton's `lsteamclient` and its Steamworks-derived content. The [licence shipped in the pinned directory](https://github.com/ValveSoftware/Proton/blob/bc896217ffcd67f892f952b010f898fe7bd0f0a1/lsteamclient/LICENSE) grants local SDK source use for developing Licensee Software and specifies distribution rights for `redistributable_bin`; it is not a general permissive source redistribution grant. Its application to this bridge needs a component-specific rights assessment. This audit establishes neither infringement nor permission. Proton's [root licence notice](https://github.com/ValveSoftware/Proton/blob/bc896217ffcd67f892f952b010f898fe7bd0f0a1/LICENSE) explicitly directs readers to component licences.

## Scope and reproducible identity

- Repository: `macos-wine-xr`.
- Patch: `patches/lsteamclient/0001-macos-host-steamclient.patch`.
- Patch SHA-256: `2006d8a2f73d390b3ca5c1a35ccc655fbb333a1396199d202396016df3c19d9f`.
- First patch commit: `b47314f81f3d9adf137cd36501090bdf966561be`, Nick Kennedy, 27 October 2026, “lsteamclient: Windows games on the macOS Steam client”. This establishes repository history, not independent proof of authorship.
- Upstream: `ValveSoftware/Proton`, commit `bc896217ffcd67f892f952b010f898fe7bd0f0a1`, `lsteamclient/`.
- Builder: `scripts/build-lsteamclient.zsh`.
- Related Wine changes: `NikNakk/wine-crossover` commits `98ad852b4b5f3d99e869194012c34133a12a9dcb` and `429799553064fa9668f87278913f23b235a473a7` in `sources/wine`.

| Patched file | Added lines | Removed lines | Context lines | Purpose |
| --- | ---: | ---: | ---: | --- |
| `unix_private.h` | 11 | 0 | 6 | Include libc++ headers before Wine macro definitions on macOS |
| `unix_steam_input_manual.cpp` | 7 | 0 | 6 | Return zero for native keyboard key code conversion on macOS |
| `unixlib.cpp` | 7 | 4 | 18 | Make two unavailable host exports optional and provide fallbacks |

Counts include blank lines and braces. They are not a measure of copyrightable expression, substantiality or independent authorship. Added lines include edits to upstream expressions.

## Findings

### 1. Unresolved redistribution rights — release decision

The build compiles downloaded Proton sources, including SDK-derived material, into `lsteamclient.dll` and `lsteamclient.so`. Those outputs are not made entirely independent code merely because the repository stores a downloader. Keep this component outside public binary releases until its rights are established. End-user builds reduce our distribution of the compiled component but do not establish that all source use, modification or patch distribution is permitted. Another project's distribution practice is not permission for this project.

### 2. Patch provenance and licence scope are not self-contained — documentation gap

The patch begins directly with a diff. It has no author/provenance preamble, exact base revision, upstream licence reference or statement distinguishing original contributions from upstream excerpts. The builder contains the pin, and Git records the patch author, but a detached patch loses this context.

Add a provenance header or adjacent notice recording the source URL, exact revision, patch author and date, and the upstream licence location. State explicitly that upstream material remains subject to its applicable terms. Establish the licence for independently authored additions with the rights holder; do not apply a blanket LGPL label to the entire diff as a way to relicense upstream material. Notices document provenance; they do not create missing rights.

### 3. Output notice handling is incomplete — packaging gap

The builder copies the whole downloaded tree, including its unchanged `LICENSE`, into the Wine source directory. However, its result-copying step (lines 127–135) copies binaries without a licence/provenance sidecar beside them. The licence remains under the source cache. A consumer selecting only the output binaries can therefore lose it.

If distribution is authorised, stage applicable notices and a component manifest with the outputs, and ensure packaging retains them. Assess any source obligations separately. Copying the notice alone would not resolve finding 1.

### 4. “Not redistributed here” needs narrower wording — misleading description

The builder's introductory comment says Valve's `lsteamclient` is “not redistributed here”. This can reasonably describe the absence of the full downloaded source tree, but it obscures the upstream excerpts in the committed patch and says nothing about redistribution of build outputs.

Use wording such as: “The full upstream source tree is fetched at build time. The adaptation patch contains upstream excerpts. Upstream material and resulting components retain their applicable licensing requirements.” The script's own LGPL SPDX identifier does not relicense fetched material.

### 5. Downloaded-source exclusion is checkout-local — portability gap

In the inspected Wine checkout, `dlls/lsteamclient/` is ignored by `.git/info/exclude`, line 7, and its `LICENSE` is not tracked. No untracked source under that directory appeared in the scoped Git status check. This is a local safeguard, not a tracked rule inherited by fresh clones. The builder itself assembles the downloaded component directly inside the Wine source checkout.

Use a disposable assembly tree or a tracked/generated-source exclusion appropriate to the fork. Do not rely on this checkout's local exclusion to prevent accidental source publication elsewhere.

### 6. Wine redirect changes have separate provenance — record exact upstream origin

The related Wine loader changes retain the existing LGPL-2.1-or-later file headers; the WoW64 change also records Nick Kennedy's copyright and LGPL identifier. These Wine changes should be assessed separately from the Steamworks-labelled component.

The port comments identify Valve's Wine `proton_11.0` branch and loader path, but not the exact originating revision for the derived implementation. Record the exact source revision and retained authorship for the port, alongside the local commits. A branch name is mutable. This audit did not prove independent authorship or perform a comprehensive similarity search against NotProton or all historical upstream versions.

## Verification and limits

The cached, pristine upstream tree matched the builder's pinned digest:

`0f0974a9e4b99cc203213c3c6c7e6d0068c54b36b309b60b7efa60b80484f77a`

The patch passed `patch --dry-run --fuzz=0 -p1` against copies of the three pinned source files. Applying it to temporary copies left the upstream licence byte-identical. No operational source tree was modified. Detailed hashes and counts were recorded locally in `build/audits/steam-bridge/evidence.json`.

The patch makes host interface lookup optional, returns true when `Steam_IsKnownInterface` is absent, and skips missing-interface notification when unavailable. No entitlement or authentication bypass is visible in these hunks. The true fallback may mask unsupported interface versions; the keyboard fallback also needs runtime validation. Neither observation establishes licensing permission or full behavioural correctness.

No full build or Steam runtime test was performed for this audit. This report does not audit every dependency, all release archives, Steam client downloads, the stand-in executable, or the complete launcher. Functional patches were left unchanged.
