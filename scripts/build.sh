#!/bin/zsh
# Generates the Xcode project, builds Release, and copies the app to ./build/NDI-Viewer.app
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project NDIViewer.xcodeproj -scheme NDIViewer -configuration "${CONFIG:-Release}" \
  -derivedDataPath .derived build -quiet
rm -rf build && mkdir -p build
cp -R ".derived/Build/Products/${CONFIG:-Release}/NDI-Viewer.app" build/
echo "Built: $(pwd)/build/NDI-Viewer.app"
