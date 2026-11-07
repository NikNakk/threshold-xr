#!/bin/zsh
# Build Threshold XR in release mode and assemble "Threshold XR.app".
#
# Usage: scripts/make-app.zsh [DESTINATION_DIR]   (default: ./build)
#   e.g. scripts/make-app.zsh /Applications
#
# Environment:
#   SIGN_IDENTITY  codesign identity, or "-" for ad hoc. By default the single
#                  valid "Apple Development" identity in the keychain, else ad hoc.
#   BUNDLE_ID      bundle identifier (default com.nickkennedy.threshold-xr)
#
# Follows SwiftXR Shell's scripts/make-app.zsh. No administrator rights are
# needed unless DESTINATION_DIR requires them.
set -euo pipefail

repo=${0:A:h:h}
destination=${1:-$repo/build}
name="Threshold XR"
executable=threshold-xr
bundle_id=${BUNDLE_ID:-com.nickkennedy.threshold-xr}

apple_development_identity() {
  local -a hashes
  hashes=(${(f)"$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development: / { print $2 }')"})
  (( ${#hashes} == 1 )) && print -r -- $hashes[1]
}

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  identity=$SIGN_IDENTITY
elif identity=$(apple_development_identity) && [[ -n $identity ]]; then
  print "Signing with Apple Development identity $identity"
else
  identity=-
  print "No single Apple Development identity found; signing ad hoc (set SIGN_IDENTITY to choose)"
fi

cd "$repo"
mkdir -p "$destination"

swift build -c release --product "$executable"
binary=$(swift build -c release --show-bin-path)/$executable

version=$(git describe --tags --always --dirty 2>/dev/null || print 0.1.0)
build=$(git rev-list --count HEAD 2>/dev/null || print 1)

# Assemble beside the destination and swap in, so a failed build never
# leaves a half-written app.
staging=$(mktemp -d "$destination/.${executable}.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$executable"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
EOF
plutil -lint -s "$app/Contents/Info.plist"

codesign --force --sign "$identity" --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"

target="$destination/$name.app"
rm -rf "$target"
mv "$app" "$target"
touch "$target"
print "Built $target ($version, build $build, signed: $identity)"
