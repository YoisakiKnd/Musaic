#!/usr/bin/env bash
# flutter_inappwebview_android 1.1.3 与 AGP 9 不兼容（proguard-android.txt 已移除）。
# pub cache 被清理后重跑本脚本即可。
set -e
F="$HOME/.pub-cache/hosted/pub.dev/flutter_inappwebview_android-1.1.3/android/build.gradle"
if [ -f "$F" ] && grep -q "proguard-android.txt" "$F"; then
  sed -i '' "s/getDefaultProguardFile('proguard-android.txt')/getDefaultProguardFile('proguard-android-optimize.txt')/g" "$F"
  echo "patched: $F"
else
  echo "no patch needed or file missing: $F"
fi
