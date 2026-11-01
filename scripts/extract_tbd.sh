#!/bin/bash
# 从 macOS SDK 递归抽取框架 .tbd 存根（供 zig 交叉编译链接 MediaPlayer 用）。
# 在 GitHub macos runner 上跑（有完整 Xcode SDK），产物 tar 上传 artifact。
set -e
SDK=$(xcrun --show-sdk-path)
WANT="MediaPlayer"
mkdir -p out/Frameworks
declare -A done
queue=("$WANT")
while [ ${#queue[@]} -gt 0 ]; do
  fw="${queue[0]}"; queue=("${queue[@]:1}")
  [ -n "${done[$fw]:-}" ] && continue
  done[$fw]=1
  src="$SDK/System/Library/Frameworks/$fw.framework/$fw.tbd"
  # 部分 framework 在 /System/Library/PrivateFrameworks 或无 tbd（跳过）
  if [ ! -f "$src" ]; then
    src="$SDK/System/Library/PrivateFrameworks/$fw.framework/$fw.tbd"
  fi
  if [ -f "$src" ]; then
    mkdir -p "out/Frameworks/$fw.framework"
    cp "$src" "out/Frameworks/$fw.framework/"
    echo "extracted: $fw"
    # 解析 reexported-libraries 递归抽取
    for dep in $(sed -n '/reexported-libraries:/,/^[a-z]/p' "$src" | grep '^\s*-\s*' | sed 's/^\s*-\s*//' | tr -d "'\"" ); do
      [ -n "${done[$dep]:-}" ] || queue+=("$dep")
    done
  else
    echo "skip (no tbd): $fw"
  fi
done
tar -czf macos-frameworks-tbd.tar.gz -C out Frameworks
echo "done: $(find out -name '*.tbd' | wc -l) tbds"
