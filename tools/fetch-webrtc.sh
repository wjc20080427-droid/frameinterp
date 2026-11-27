#!/bin/zsh
# 下载原生 Xbox 串流要用的 WebRTC（stasel/WebRTC 社区编译的 Google WebRTC，BSD 许可），核对 SHA-256 后解压到 Vendor/。
# 用法：tools/fetch-webrtc.sh（约 46 MB）
set -e
cd "$(dirname "$0")/.."
VER=158.0.0
FILE=WebRTC-M158.xcframework.zip
SHA=dd26ba28fb9c8dbc82f4be3085e8d112a4e2a4e654e1786a9977a748c24c4912
TMP=$(mktemp -d)
echo "下载 $FILE …"
curl -L --fail -o "$TMP/$FILE" "https://github.com/stasel/WebRTC/releases/download/$VER/$FILE"
GOT=$(shasum -a 256 "$TMP/$FILE" | cut -d' ' -f1)
if [ "$GOT" != "$SHA" ]; then echo "校验和不对（$GOT），不用这个文件"; rm -rf "$TMP"; exit 1; fi
mkdir -p Vendor
rm -rf Vendor/WebRTC.xcframework
ditto -x -k "$TMP/$FILE" "$TMP/x"
mv "$TMP/x/WebRTC.xcframework" Vendor/
rm -rf "$TMP"
echo "好了：Vendor/WebRTC.xcframework"
