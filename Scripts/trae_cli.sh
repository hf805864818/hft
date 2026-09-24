#!/bin/sh
#
# trae_cli.sh — 越狱终端版（root）探测 / 重置 iOS 版 Trae 设备标识与凭证
#
# 适用：Relaxin（RootHide 越狱）等有 root 文件系统访问的环境。
# 用法（需 root）：
#   sudo sh trae_cli.sh probe          # 探测：列出 Trae 容器 + 可疑 device id（安全，无副作用）
#   sudo sh trae_cli.sh reset          # 重置设备ID + 清凭证（自动备份 .bak）
#   sudo sh trae_cli.sh restore        # 从 .bak 恢复
#
# 说明：App（TrollStore）能处理"文件型"数据；本脚本额外覆盖
#       "Keychain 型 / 系统容器"场景（越狱终端能碰到更多路径）。
#

set -u

DATA_ROOTS="/var/mobile/Containers/Data/Application /private/var/mobile/Containers/Data/Application"
BUNDLE_ROOTS="/var/containers/Bundle/Application /private/var/containers/Bundle/Application"

# 读 plist 某个键（iOS 自带 plutil）
plist_get() {
  # $1=plist  $2=key
  plutil -extract "$2" -raw "$1" 2>/dev/null
}

find_trae_containers() {
  # 打印 "uuid  bundleid  dataPath"
  for r in $BUNDLE_ROOTS; do
    [ -d "$r" ] || continue
    for d in "$r"/*/; do
      [ -d "$d" ] || continue
      uuid=$(basename "$d")
      # 找该容器下的 .app/Info.plist
      for app in "$d"*.app; do
        [ -d "$app" ] || continue
        ip="$app/Info.plist"
        [ -f "$ip" ] || continue
        bid=$(plist_get "$ip" CFBundleIdentifier)
        nm=$(plist_get "$ip" CFBundleDisplayName)
        [ -z "$nm" ] && nm=$(plist_get "$ip" CFBundleName)
        echo "$bid $nm" | grep -qi "trae" && {
          data=""
          for dr in $DATA_ROOTS; do
            [ -d "$dr/$uuid" ] && data="$dr/$uuid" && break
          done
          echo "$uuid | $bid | $data"
        }
      done
    done
  done
}

cmd_probe() {
  echo "=== 查找 Trae 容器 ==="
  found=$(find_trae_containers)
  if [ -z "$found" ]; then
    echo "未找到含 'trae' 的容器。请用 App 内探测或手动确认 bundle id。"
    echo "可列出全部容器供参考："
    for r in $DATA_ROOTS; do
      [ -d "$r" ] && echo "[data] $r" && ls -1 "$r" 2>/dev/null | head -n 40
    done
    return 1
  fi
  echo "$found"
  echo
  for line in $found; do
    # line 形如 "uuid | bid | data"，用 | 分隔
    uuid=$(echo "$line" | cut -d'|' -f1)
    bid=$(echo "$line" | cut -d'|' -f2)
    data=$(echo "$line" | cut -d'|' -f3)
    echo "=== 容器 $bid (uuid=$uuid) ==="
    echo "数据目录: $data"
    [ -z "$data" ] && continue
    echo "--- 疑似 device id 文件 ---"
    find "$data" -maxdepth 4 -type f 2>/dev/null \
      | grep -iE 'machineid|deviceid|device_id|machine_id|machine\.id' || echo "(无)"
    echo "--- JSON 中含 device/telemetry/sqm/machine 键的文件 ---"
    for j in $(find "$data" -maxdepth 6 -type f -name '*.json' 2>/dev/null); do
      grep -liE 'telemetry|devdeviceid|machineid|sqmid|machineId' "$j" 2>/dev/null
    done
    echo
  done
  echo "提示: 登录凭证 / 部分 device id 常存于系统 Keychain（kdbx）。"
  echo "  若存在 keychaindumper（越狱包），可导出后核对。"
  echo "  RootHide 越狱下:  /var/Keychain/ 或  通过 'kdump' / 越狱工具访问。"
}

cmd_reset() {
  for line in $(find_trae_containers); do
    data=$(echo "$line" | cut -d'|' -f3)
    [ -z "$data" ] && continue
    echo "=== 重置 $data ==="
    # 1) machineid 类文件
    for f in $(find "$data" -maxdepth 4 -type f 2>/dev/null | grep -iE 'machineid$|deviceid$|machine_id$'); do
      cp -f "$f" "$f.bak" 2>/dev/null
      newid=$(cat /dev/urandom | od -An -tu2 -N4 | tr -d ' ' | head -c32)
      # 生成标准 UUID 形态
      if command -v python3 >/dev/null 2>&1; then
        newid=$(python3 -c 'import uuid;print(uuid.uuid4())')
      else
        # shell 生成 8-4-4-4-12
        hex=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c32)
        newid="${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
      fi
      printf '%s' "$newid" > "$f"
      echo "  重置: $f -> $newid"
    done
    # 2) JSON telemetry.* / device 键
    for j in $(find "$data" -maxdepth 6 -type f -name '*.json' 2>/dev/null); do
      if grep -qiE 'telemetry|devdeviceid|machineid|sqmid' "$j" 2>/dev/null; then
        if command -v python3 >/dev/null 2>&1; then
          cp -f "$j" "$j.bak"
          python3 - "$j" <<'PY'
import sys, json, uuid, secrets
p = sys.argv[1]
with open(p) as f: d = json.load(f)
if 'telemetry' in d and isinstance(d['telemetry'], dict):
    d['telemetry']['machineId'] = secrets.token_hex(32)
    d['telemetry']['devDeviceId'] = str(uuid.uuid4())
    d['telemetry']['sqmId'] = '{' + str(uuid.uuid4()).upper() + '}'
    print('  重置 telemetry @', p)
with open(p,'w') as f: json.dump(d, f, indent=2)
PY
        fi
      fi
    done
  done
  echo "完成。重开 Trae 再登录。若仍受限，说明是 Keychain/服务端 绑定，需进一步处理。"
}

cmd_restore() {
  for line in $(find_trae_containers); do
    data=$(echo "$line" | cut -d'|' -f3)
    [ -z "$data" ] && continue
    for b in $(find "$data" -maxdepth 6 -type f -name '*.bak' 2>/dev/null); do
      orig="${b%.bak}"
      cp -f "$b" "$orig" && echo "  恢复: $orig"
    done
  done
}

case "${1:-probe}" in
  probe)   cmd_probe ;;
  reset)   cmd_reset ;;
  restore) cmd_restore ;;
  *) echo "用法: sh trae_cli.sh [probe|reset|restore]"; exit 2 ;;
esac
