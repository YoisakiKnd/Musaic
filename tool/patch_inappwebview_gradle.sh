#!/usr/bin/env bash
# flutter_inappwebview_android 1.1.3 与 AGP 9 不兼容（proguard-android.txt 已移除）。
# pub cache 被清理后重跑本脚本即可。
set -e
patched=0
for root in "${PUB_CACHE:-}" "$HOME/.pub-cache" "$HOME/.pub-cache-user"; do
  [ -n "$root" ] || continue
  F="$root/hosted/pub.dev/flutter_inappwebview_android-1.1.3/android/build.gradle"
  if [ -f "$F" ] && grep -q "proguard-android.txt" "$F"; then
    sed -i '' "s/getDefaultProguardFile('proguard-android.txt')/getDefaultProguardFile('proguard-android-optimize.txt')/g" "$F"
    echo "patched: $F"
    patched=1
  fi
done
if [ "$patched" -eq 0 ]; then
  echo "no patch needed or file missing"
fi
