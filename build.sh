#!/bin/zsh
set -e
D=${0:A:h}
A="$D/HeadMouseSpike.app"
pkill -x HeadMouseSpike 2>/dev/null || true
mkdir -p "$A/Contents/MacOS"
cat > "$A/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.spike.headmouse2</string>
<key>CFBundleName</key><string>HeadMouseSpike</string>
<key>CFBundleExecutable</key><string>HeadMouseSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSMotionUsageDescription</key><string>Moves the cursor from AirPods head motion.</string>
</dict></plist>
EOF
swiftc -swift-version 5 -O "$D/main.swift" -o "$A/Contents/MacOS/HeadMouseSpike" -framework CoreMotion -framework AppKit -framework Carbon
codesign --force --sign "NotchPill Self-Signed" "$A"
codesign -dv "$A" 2>&1 | grep -E '^(Identifier|Signature|Authority)'
echo built
