#!/bin/sh
# Builds "Agent Radar.app" in build/ (release).
#   --universal  builds for both Apple silicon and Intel (slower; used for the DMG in CI)
#   --dmg        also creates build/Agent-Radar-<version>.dmg
#   --install    copies the app to ~/Applications and (re)starts it
# Signing: with SIGN_IDENTITY (e.g. "Developer ID Application") if set, otherwise with the first Developer ID
# Application or Apple Development certificate in the keychain, otherwise ad-hoc. SIGN_IDENTITY=- forces ad-hoc.
# A certificate signs the app and the DMG with the hardened runtime and a secure timestamp, as notarization
# requires. Unlike ad-hoc signing, it keeps macOS privacy permissions (such as Desktop access) across builds.
set -e

cd "$(dirname "$0")/.."
name="Agent Radar"
app="build/$name.app"
if [ -n "${SIGN_IDENTITY+set}" ]; then
  identity="${SIGN_IDENTITY:--}"
else
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  identity=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)
  [ -n "$identity" ] ||
    identity=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' | head -n 1)
  [ -n "$identity" ] || identity=-
fi

universal=false dmg=false install=false
for arg in "$@"; do
  case "$arg" in
    --universal) universal=true ;;
    --dmg) dmg=true ;;
    --install) install=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$universal" = true ]; then
  set -- -c release --arch arm64 --arch x86_64
else
  set -- -c release
fi
swift build "$@"
bin=$(swift build "$@" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/AgentRadar" "$app/Contents/MacOS/AgentRadar"
version=$(git describe --tags --always 2>/dev/null || echo 0.1)
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>nl.webhare.agent-radar</string>
  <key>CFBundleExecutable</key><string>AgentRadar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 WebHare b.v. GNU GPL version 2.</string>
  <key>NSAppleEventsUsageDescription</key><string>Agent Radar asks Terminal which tab is in front and brings a session's tab forward when you click it.</string>
</dict>
</plist>
EOF

if [ "$identity" = "-" ]; then
  codesign --force --sign - "$app"
else
  # The hardened runtime blocks Apple Events (used to talk to Terminal.app) unless the entitlement allows them.
  codesign --force --sign "$identity" --options runtime --timestamp \
    --entitlements scripts/AgentRadar.entitlements "$app"
fi
codesign --verify --strict "$app"
echo "Built $app ($version, signed by $identity)"

if [ "$dmg" = true ]; then
  image="build/Agent-Radar-$version.dmg"
  staging="build/dmg"
  rm -rf "$staging" "$image"
  mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -quiet -volname "$name" -srcfolder "$staging" -fs HFS+ -format UDZO "$image"
  rm -rf "$staging"
  if [ "$identity" != "-" ]; then
    codesign --sign "$identity" --timestamp "$image"
  fi
  echo "Built $image"
fi

if [ "$install" = true ]; then
  mkdir -p "$HOME/Applications"
  pkill -x AgentRadar 2>/dev/null || true
  rm -rf "$HOME/Applications/$name.app"
  cp -R "$app" "$HOME/Applications/"
  open "$HOME/Applications/$name.app"
  echo "Installed and started $HOME/Applications/$name.app"
fi
