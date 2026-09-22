#!/bin/zsh
# Builds ReelFlow in release, wraps it in ReelFlow.app, signs it, installs
# it to /Applications and launches it. Run from anywhere:
#   ~/Developer/ReelFlow/scripts/build-app.sh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/.build"
app_dir="$build_dir/ReelFlow.app"

cd "$project_dir"
swift build -c release --disable-sandbox

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/ReelFlow" "$app_dir/Contents/MacOS/ReelFlow"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
sign_identity=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
for attempt in 1 2; do
  xattr -cr "$app_dir"
  if codesign --force --deep --sign "${sign_identity:--}" "$app_dir"; then break; fi
  [[ $attempt == 2 ]] && exit 1
  sleep 0.5
done

installed_app="/Applications/ReelFlow.app"
osascript -e 'tell application id "io.reelflow.ReelFlow" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq ReelFlow || break; sleep 0.3; done
rm -rf "$installed_app"
cp -R "$app_dir" "$installed_app"
open "$installed_app"
