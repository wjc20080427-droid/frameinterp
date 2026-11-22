#!/bin/zsh
# 编译并打包成 FrameInterp.app（双击就能打开）。用法：./make-app.sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=FrameInterp.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/FrameInterp $APP/Contents/MacOS/FrameInterp
# 图标：tools/make-icon.swift 画出 1024 图，再做成 .icns
if [ ! -f build-assets/AppIcon.icns ] || [ tools/make-icon.swift -nt build-assets/AppIcon.icns ]; then
  mkdir -p build-assets && rm -rf build-assets/AppIcon.iconset && mkdir build-assets/AppIcon.iconset
  swift tools/make-icon.swift build-assets/icon-src.png > /dev/null
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz build-assets/icon-src.png --out build-assets/AppIcon.iconset/icon_${sz}x${sz}.png > /dev/null
    sips -z $((sz*2)) $((sz*2)) build-assets/icon-src.png --out build-assets/AppIcon.iconset/icon_${sz}x${sz}@2x.png > /dev/null
  done
  iconutil -c icns build-assets/AppIcon.iconset -o build-assets/AppIcon.icns
fi
cp build-assets/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FrameInterp</string>
    <key>CFBundleIdentifier</key><string>local.frameinterp</string>
    <key>CFBundleName</key><string>FrameInterp</string>
    <key>CFBundleDisplayName</key><string>FrameInterp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>2.5</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>Reads the capture card picture for frame interpolation. 读取采集卡画面用于补帧。</string>
    <key>NSMicrophoneUsageDescription</key><string>Plays the capture card audio through your speakers. 把采集卡的声音直通到扬声器。</string>
</dict>
</plist>
PLIST
# 本机临时签名（权限会记在这个签名上；重新打包后系统可能再问一次权限）
codesign --force --deep --sign - --requirements "=designated => identifier \"local.frameinterp\"" $APP
echo "已生成 $(pwd)/$APP"
