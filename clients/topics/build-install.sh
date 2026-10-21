#!/bin/sh
# Builds Topics (Debug, signed with the Personal Team) and installs it to
# ~/Applications/Topics.app. Extra arguments are passed to the app on launch.
set -e
cd "$(dirname "$0")"
xcodebuild -project Topics.xcodeproj -scheme Topics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -quiet build
pkill -x Topics 2>/dev/null || true
rm -rf "$HOME/Applications/Topics.app"
ditto build/DerivedData/Build/Products/Debug/Topics.app "$HOME/Applications/Topics.app"
if [ "$#" -gt 0 ]; then
  open "$HOME/Applications/Topics.app" --args "$@"
else
  open "$HOME/Applications/Topics.app"
fi
