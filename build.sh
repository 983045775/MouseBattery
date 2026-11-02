#!/bin/bash
# MouseBattery 构建脚本：编译内嵌 hidapi + Swift，打包成 .app
set -e
cd "$(dirname "$0")"

echo "== 编译 hidapi C 库 =="
cc -O2 -c hidapi/mac/hid.c -Ihidapi -o hid.o
cc -O2 -c atk_bridge.c -Ihidapi -o bridge.o

echo "== 编译 Swift =="
swiftc -O -import-objc-header atk_bridge.h MouseBattery.swift bridge.o hid.o \
    -framework AppKit -framework IOKit -framework CoreFoundation \
    -o MouseBattery

echo "== 打包 MouseBattery.app =="
rm -rf MouseBattery.app
mkdir -p MouseBattery.app/Contents/MacOS MouseBattery.app/Contents/Resources
cp MouseBattery MouseBattery.app/Contents/MacOS/MouseBattery
cp AppIcon.icns MouseBattery.app/Contents/Resources/AppIcon.icns
cat > MouseBattery.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>MouseBattery</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.atk.mousebattery</string>
	<key>CFBundleName</key><string>MouseBattery</string>
	<key>CFBundleDisplayName</key><string>ATK 鼠标电量</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --deep -s - MouseBattery.app

echo "OK: $(pwd)/MouseBattery.app"
