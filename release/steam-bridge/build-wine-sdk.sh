#!/bin/bash
# Copyright 2026 Nick Kennedy
# SPDX-License-Identifier: LGPL-2.1-or-later
# Maintainer/CI producer. Builds Wine from a pinned, clean checkout; never builds Steam code.
set -euo pipefail
tools=$(cd "$(dirname "$0")" && pwd)
: "${WINE_REVISION:=3eacaecc354e00c6e1d5bd23dc3e7a5ee5eb0ede}"
: "${SDK_WORK:?Set SDK_WORK to a new, absolute working directory}"
: "${SDK_VERSION:?Set SDK_VERSION to a version for this paired runtime and SDK}"
[[ "$WINE_REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo 'WINE_REVISION must be a full commit hash' >&2; exit 2; }
[[ "$SDK_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$ ]] || { echo 'Invalid SDK_VERSION' >&2; exit 2; }
[[ "$SDK_WORK" = /* && ! -e "$SDK_WORK" ]] || { echo 'SDK_WORK must be a new absolute directory' >&2; exit 2; }
mkdir -p "$SDK_WORK"
git init "$SDK_WORK/wine"
git -C "$SDK_WORK/wine" remote add origin https://github.com/NikNakk/wine-crossover.git
git -C "$SDK_WORK/wine" fetch --depth=1 origin "$WINE_REVISION"
git -C "$SDK_WORK/wine" checkout --detach FETCH_HEAD
[[ $(git -C "$SDK_WORK/wine" rev-parse HEAD) == "$WINE_REVISION" ]]
grep -q MWXR_LSTEAMCLIENT "$SDK_WORK/wine/dlls/ntdll/loader.c" || {
  echo 'Selected Wine revision lacks the Steam redirect' >&2; exit 1;
}
# Use the same recipe as the managed Wine release. Configuration/build logs remain local.
cd "$SDK_WORK/wine"
export COMPONENT=wine PLATFORM=macos-x86_64 VERSION="$SDK_VERSION" PREFIX="$SDK_WORK/runtime"
bash "$tools/../build.sh"
python3 "$tools/../package.py" package --component wine --version "$SDK_VERSION" \
  --platform macos-x86_64 --role compatibility-layer --prefix "$PREFIX" --output "$SDK_WORK/dist"
# Export only after relocation/signing, so the hashes match the packaged runtime.
python3 "$tools/bridge.py" export-sdk --wine-source "$SDK_WORK/wine" \
  --wine-build "$SDK_WORK/wine/.threshold-build" --runtime "$PREFIX" \
  --version "$SDK_VERSION" --output "$SDK_WORK/sdk"
python3 "$tools/bridge.py" archive-sdk --sdk "$SDK_WORK/sdk" --output "$SDK_WORK/dist/wine-bridge-sdk-$SDK_VERSION.tar.gz"
