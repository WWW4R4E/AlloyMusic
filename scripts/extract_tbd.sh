#!/bin/bash
# 从 macOS SDK 递归抽取框架 .tbd 存根（供 zig 交叉编译链接 MediaPlayer 用）。
# 在 GitHub macos runner 上跑（有完整 Xcode SDK），产物 tar 上传 artifact。
# 注意 macOS 自带 bash 3.2：不用关联数组。
set -e
SDK=$(xcrun --show-sdk-path)
mkdir -p out/Frameworks
queue="MediaPlayer"
extracted=""
while [ -n "$queue" ]; do
  fw="${queue%% *}"; [ "$queue" = "$fw" ] && queue=""
  queue="${queue#* }"
  [ -z "$fw" ] && continue
  echo "$extracted" | grep -qx "$fw" && continue
  src="$SDK/System/Library/Frameworks/$fw.framework/$fw.tbd"
  [ -f "$src" ] || src="$SDK/System/Library/PrivateFrameworks/$fw.framework/$fw.tbd"
  if [ -f "$src" ]; then
    mkdir -p "out/Frameworks/$fw.framework"
    cp "$src" "out/Frameworks/$fw.framework/"
    extracted="$extracted $fw"
    echo "extracted: $fw"
    for dep in $(sed -n '/reexported-libraries:/,/^[a-zA-Z]/p' "$src" | grep '^[[:space:]]*-' | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d "'\""); do
      echo "$extracted" | grep -qx "$dep" || queue="$queue $dep"
    done
  else
    echo "skip (no tbd): $fw"
    extracted="$extracted $fw"
  fi
done
cp "$SDK/usr/lib/libobjc.tbd" out/Frameworks/ 2>/dev/null || echo "skip libobjc.tbd"
tar -czf macos-frameworks-tbd.tar.gz -C out Frameworks
echo "done: $(find out -name "*.tbd" | wc -l | tr -d ' ') tbds"
