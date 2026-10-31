#!/bin/zsh
# Build Cadence for iPhone and run it in the simulator, with its icon.
#
# This Mac's Xcode has the iOS 26.5 SDK but only an iOS 17.4 simulator, and Xcode's asset step refuses
# to build for a simulator it can't match. So the asset catalog is left out of the build and the icon
# is added afterwards as plain image files, which iOS also accepts. Real device and App Store builds
# from Xcode don't need this.
#
# Usage: scripts/ios-sim.sh ["iPhone 15 Pro Max"] [launch args...]
set -e
cd "${0:a:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE=${1:-"iPhone 15 Pro Max"}; shift 2>/dev/null || true
APP=build/ios/Debug-iphonesimulator/Cadence.app

xcodegen generate -q
xcodebuild -project Cadence.xcodeproj -target CadenceMobile -sdk iphonesimulator26.5 -configuration Debug \
  SYMROOT=$PWD/build/ios ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets build | grep -E "error:|BUILD" || true
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

# The icon: compile the catalog on its own (that works without a matching simulator) and copy the images in.
ICONS=$(mktemp -d)
xcrun actool iOS/Assets.xcassets --compile "$ICONS" --platform iphonesimulator --minimum-deployment-target 17.0 \
  --app-icon AppIcon --target-device iphone --output-partial-info-plist "$ICONS/icons.plist" >/dev/null || true
# (actool still complains about the simulator runtime, but it writes the icon images and plist first.)
[ -f "$ICONS/icons.plist" ] || { echo "Icon step failed"; exit 1; }
cp "$ICONS"/AppIcon*.png "$APP/"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Merge $ICONS/icons.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$APP/Info.plist" 2>/dev/null || true
rm -rf "$ICONS"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --terminate-running-process "$DEVICE" com.ryanpark.cadence.ios "$@" >/dev/null
echo "Running on $DEVICE"
