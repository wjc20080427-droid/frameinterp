#!/bin/zsh
# 编译并打包成 FrameInterp.app（双击就能打开）。用法：./make-app.sh
#   有 Vendor/WebRTC.xcframework（tools/fetch-webrtc.sh 下载）时带原生 Xbox 串流（FI_XNATIVE）；没有就是不带的版本（Xbox 用内嵌网页）。
#   ./make-app.sh keypad：测试版，再加「键盘当手柄」（FI_KEYPAD）。发布用的 DMG（make-release.sh）不带键盘手柄
set -e
cd "$(dirname "$0")"
if [ -d Vendor/WebRTC.xcframework ]; then
  if [ "$1" = "keypad" ]; then
    FI_XNATIVE=1 FI_KEYPAD=1 swift build -c release --scratch-path .build-test
    BIN=.build-test/release
  else
    FI_XNATIVE=1 swift build -c release --scratch-path .build-native
    BIN=.build-native/release
  fi
else
  echo "（没有 Vendor/WebRTC.xcframework：不带原生 Xbox 串流。要带的话先运行 tools/fetch-webrtc.sh）"
  swift build -c release
  BIN=.build/release
fi
# 先在临时目录（不在 iCloud 同步的桌面里）拼好、签好名，再拷回来：桌面开了 iCloud 同步时，系统会给 .app / .framework 文件夹
# 加 Finder 信息，codesign 报"resource fork, Finder information, or similar detritus not allowed"（2026-11-27 加了 WebRTC 框架后遇到）
FINAL=FrameInterp.app
STAGE=$(mktemp -d)
APP=$STAGE/FrameInterp.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/FrameInterp $APP/Contents/MacOS/FrameInterp
# 测试版：WebRTC 框架放进 Contents/Frameworks（程序按 @executable_path/../Frameworks 找）
if [ -d $BIN/WebRTC.framework ]; then
  mkdir -p $APP/Contents/Frameworks
  ditto --noextattr $BIN/WebRTC.framework $APP/Contents/Frameworks/WebRTC.framework
  F=$APP/Contents/Frameworks/WebRTC.framework
  rm -rf $F/Headers $F/Modules $F/Versions/A/Headers $F/Versions/A/Modules   # 运行时用不到
  cp Vendor/WebRTC.xcframework/LICENSE $APP/Contents/Resources/WebRTC-LICENSE.txt   # BSD 许可要求随二进制附带
fi
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
    <key>CFBundleShortVersionString</key><string>2.6.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>Reads the capture card picture for frame interpolation. 读取采集卡画面用于补帧。</string>
    <key>NSMicrophoneUsageDescription</key><string>Plays the capture card audio through your speakers. 把采集卡的声音直通到扬声器。</string>
</dict>
</plist>
PLIST
# 签名：钥匙串里有本机证书「FrameInterp Local Signing」就用它——签名固定（App 标识 + 证书），重新编译后录屏 / 摄像头权限不会丢
# （2026-11-27 加：临时签名每次编译都变，macOS 27 每次都把录屏权限重置）。没有这个证书（别的电脑）就退回临时签名
xattr -cr $APP
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"FrameInterp Local Signing"/ {print $2; exit}')
if [ -n "$ID" ]; then
  [ -d $APP/Contents/Frameworks/WebRTC.framework ] && codesign --force --sign "$ID" $APP/Contents/Frameworks/WebRTC.framework
  codesign --force --sign "$ID" $APP
else
  codesign --force --deep --sign - --requirements "=designated => identifier \"local.frameinterp\"" $APP
fi
codesign --verify --deep --strict $APP
rm -rf $FINAL
ditto $APP $FINAL
rm -rf $STAGE
echo "已生成 $(pwd)/$FINAL"
