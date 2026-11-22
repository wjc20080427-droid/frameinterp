#!/bin/zsh
# 打包发布：生成 ../FrameInterp-版本.dmg（放在 framedoubler 文件夹）（里面有 App、"应用程序"快捷方式和安装说明）。用法：./make-release.sh
set -e
cd "$(dirname "$0")"
./make-app.sh
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" FrameInterp.app/Contents/Info.plist)
STAGE=$(mktemp -d)
OUTDIR="$(cd .. && pwd)"
ditto FrameInterp.app "$STAGE/FrameInterp.app"
ln -s /Applications "$STAGE/应用程序"
cp release/安装说明.txt "$STAGE/安装说明.txt"
OUT="$OUTDIR/FrameInterp-$VER.dmg"
rm -f "$OUT"
hdiutil create -volname "FrameInterp $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" > /dev/null
rm -rf "$STAGE"
echo "已生成 $OUT（$(du -h "$OUT" | cut -f1)）"
