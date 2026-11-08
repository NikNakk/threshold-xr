#!/bin/zsh
# Build Threshold XR in release mode and assemble "Threshold XR.app", with
# Threshold Home inside it as Contents/Helpers/Threshold Home.app.
#
# Usage: scripts/make-app.zsh [DESTINATION_DIR]   (default: ./build)
#   e.g. scripts/make-app.zsh /Applications
#
# Environment:
#   SIGN_IDENTITY  codesign identity, or "-" for ad hoc. By default the single
#                  valid "Apple Development" identity in the keychain, else ad hoc.
#   BUNDLE_ID      bundle identifier (default com.nickkennedy.threshold-xr)
#   HOME_BUNDLE_ID Threshold Home's identifier (default com.nickkennedy.swiftxr-shell,
#                  SwiftXR Shell's, so its Screen Recording and Accessibility
#                  permissions carry over)
#
# Threshold Home needs the Khronos OpenXR loader in /usr/local/lib and SwiftXR
# (see README). Set SKIP_HOME=1 to build Threshold XR alone.
#
# Follows SwiftXR Shell's scripts/make-app.zsh. No administrator rights are
# needed unless DESTINATION_DIR requires them.
set -euo pipefail

repo=${0:A:h:h}
destination=${1:-$repo/build}
name="Threshold XR"
executable=threshold-xr
bundle_id=${BUNDLE_ID:-com.nickkennedy.threshold-xr}
icon_source="$repo/Resources/AppIcon.png"
home_name="Threshold Home"
home_executable=swiftxr-shell
home_bundle_id=${HOME_BUNDLE_ID:-com.nickkennedy.swiftxr-shell}
home_icon_source="$repo/ThresholdHome/Resources/AppIcon.png"

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
bin_path=$(swift build -c release --show-bin-path)
binary=$bin_path/$executable
if [[ -z ${SKIP_HOME:-} ]]; then
  swift build -c release --product "$home_executable"
fi

version=$(git describe --tags --always --dirty 2>/dev/null || print 0.1.0)
build=$(git rev-list --count HEAD 2>/dev/null || print 1)

# Assemble beside the destination and swap in, so a failed build never
# leaves a half-written app.
staging=$(mktemp -d "$destination/.${executable}.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$executable"

# Every standard macOS icon size from 1024px artwork
# (regenerate it with Tools/Icons/make-icon.swift).
make_icns() { # source output
  local iconset="$staging/AppIcon-$RANDOM.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$1" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$1" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$2"
}
make_icns "$icon_source" "$app/Contents/Resources/AppIcon.icns"

# Threshold Home: a background helper (LSUIElement: no Dock icon or menu bar)
# that Threshold XR starts, stops and shows the status of.
if [[ -z ${SKIP_HOME:-} ]]; then
  home_app="$app/Contents/Helpers/$home_name.app"
  mkdir -p "$home_app/Contents/MacOS" "$home_app/Contents/Resources"
  cp "$bin_path/$home_executable" "$home_app/Contents/MacOS/$home_executable"
  make_icns "$home_icon_source" "$home_app/Contents/Resources/AppIcon.icns"
  cat > "$home_app/Contents/Info.plist" <<HOMEPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$home_name</string>
  <key>CFBundleDisplayName</key><string>$home_name</string>
  <key>CFBundleIdentifier</key><string>$home_bundle_id</string>
  <key>CFBundleExecutable</key><string>$home_executable</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
HOMEPLIST
  plutil -lint -s "$home_app/Contents/Info.plist"
  # Sign the helper before the app that contains it.
  codesign --force --sign "$identity" --identifier "$home_bundle_id" "$home_app"
fi

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
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
# Refresh Launch Services so Finder and the Dock show the new icon.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x $lsregister ]] && "$lsregister" -f "$target" || true
print "Built $target ($version, build $build, signed: $identity)"
