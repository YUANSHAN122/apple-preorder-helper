#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build dist
APP="build/苹果预购助手.app"
mkdir -p "$APP/Contents/MacOS"
for ARCH in arm64 x86_64; do
  swiftc main.swift -target "$ARCH-apple-macos13.0" -o "build/helper-$ARCH" -framework Cocoa -framework WebKit -framework JavaScriptCore
done
lipo -create build/helper-arm64 build/helper-x86_64 -output "$APP/Contents/MacOS/ApplePurchaseHelper"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
"$APP/Contents/MacOS/ApplePurchaseHelper" --self-test
cp README.md build/使用说明.md
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/ApplePurchaseHelper-macOS-universal.zip
python3 - <<'PY'
from pathlib import Path
import hashlib
p=Path('dist/ApplePurchaseHelper-macOS-universal.zip')
Path('dist/SHA256SUMS.txt').write_text(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n')
PY
