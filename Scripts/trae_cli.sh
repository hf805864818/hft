#!/bin/sh
#
# trae_cli.sh — 越狱终端版（root）Trae iOS 设备标识 全链路 探测 / 重置
#
# 适用：Relaxin(RootHide) 等越狱环境，有 root 文件系统访问 + 越狱终端(NewTerm/ssh/SiriCydia)。
#
# 子命令：
#   probe      定位 Trae 容器 + 文件型 device id + Keychain 探测（安全，无副作用）
#   reset      重置文件型 device id + 清登录凭证（自动备份 .bak）
#   keychain   探测/dump Keychain 中疑似 device id 条目（需越狱有 keychaindumper 或 sqlite3）
#   restore    从 .bak 恢复
#   all        probe -> reset（自动先探测再重置）
#
# 说明：iOS 版 Trae 的设备标识官方未公开，可能落在三种位置，本脚本覆盖全部：
#   1) 沙盒文件型（machineid / storage.json telemetry.*）  -> reset 可改
#   2) Keychain 里的 UUID/标识                            -> keychain 子命令探测/导出
#   3) IDFV / 服务端账号绑定                               -> 本地无法改（文末说明）
#

set -u

ROOT_HINT="/var/jb"   # RootHide 越狱的 root 重定向前缀（部分工具装在这）
DATA_ROOTS="/var/mobile/Containers/Data/Application /private/var/mobile/Containers/Data/Application /var/containers/Data/Application"
BUNDLE_ROOTS="/var/containers/Bundle/Application /private/var/containers/Bundle/Application /var/mobile/Containers/Bundle/Application"
KEYCHAIN_DIR="/var/Keychains"

plist_get() { plutil -extract "$2" -raw "$1" 2>/dev/null; }

# 找 Trae 容器：输出 "uuid | bid | dataPath"
find_trae() {
  for r in $BUNDLE_ROOTS; do
    [ -d "$r" ] || continue
    for d in "$r"/*/; do
      [ -d "$d" ] || continue
      uuid=$(basename "$d")
      case "$uuid" in
        *[!0-9a-fA-F-]*) continue;;   # 非 UUID 跳过
      esac
      for app in "$d"*.app; do
        [ -d "$app" ] || continue
        ip="$app/Info.plist"; [ -f "$ip" ] || continue
        bid=$(plist_get "$ip" CFBundleIdentifier)
        nm=$(plist_get "$ip" CFBundleDisplayName)
        [ -z "$nm" ] && nm=$(plist_get "$ip" CFBundleName)
        if echo " $bid $nm " | tr 'A-Z' 'a-z' | grep -q "trae"; then
          data=""
          for dr in $DATA_ROOTS; do
            [ -d "$dr/$uuid" ] && { data="$dr/$uuid"; break; }
          done
          echo "$uuid | $bid | $data"
        fi
      done
    done
  done
}

cmd_probe() {
  echo "=== [1/3] 定位 Trae 容器 ==="
  found=$(find_trae)
  if [ -z "$found" ]; then
    echo "未找到 bundle id / 名称含 'trae' 的容器。"
    echo "请确认 App 名（iOS 版 Trae 的 bundle id 可能不含 'trae' 字样，如 com.xxx.icube）。"
    echo "列出所有容器的前 30 个供你辨认 bundle id："
    for dr in $DATA_ROOTS; do
      [ -d "$dr" ] && ls -1 "$dr" 2>/dev/null | head -30 && break
    done
    echo "把上面疑似 Trae 的 bundle id 告诉我，我加进匹配词。"
    return 1
  fi
  echo "$found"

  for line in $found; do
    uuid=$(echo "$line" | cut -d'|' -f1)
    bid=$(echo "$line" | cut -d'|' -f2)
    data=$(echo "$line" | cut -d'|' -f3)
    echo
    echo "=== 容器: $bid (uuid=$uuid) ==="
    echo "数据目录: $data"
    [ -z "$data" ] && { echo "  (未找到 data 容器)"; continue; }

    echo "--- 文件型 device id ---"
    find "$data" -maxdepth 5 -type f 2>/dev/null \
      | grep -iE 'machineid|deviceid|device_id|machine_id|machine\.id|clientid' \
      || echo "  (无 machineid/deviceid 类文件)"

    echo "--- 含 device/telemetry 键的 JSON ---"
    for j in $(find "$data" -maxdepth 6 -type f -name '*.json' 2>/dev/null); do
      grep -liE 'telemetry|devdeviceid|machineid|sqmid|machineId' "$j" 2>/dev/null
    done

    echo "--- 登录凭证(Cookies/token plist) ---"
    find "$data" -maxdepth 5 -type f 2>/dev/null \
      | grep -iE 'cookies|token|auth|keychain' | head -20 || echo "  (无)"
  done

  echo
  echo "=== [2/3] Keychain 探测（见 keychain 子命令） ==="
  echo "=== [3/3] 若以上都没有 device 文件：说明 device id 存 Keychain 或 服务端 ==="
  echo "运行:  $0 keychain   查看 Keychain 里是否有设备标识"
}

cmd_reset() {
  for line in $(find_trae); do
    data=$(echo "$line" | cut -d'|' -f3)
    [ -z "$data" ] && continue
    echo "=== 重置 $data ==="
    # 1) machineid / deviceid 类文件 -> 重新生成 UUID
    for f in $(find "$data" -maxdepth 5 -type f 2>/dev/null | grep -iE 'machineid$|deviceid$|machine_id$|device_id$|clientid$'); do
      cp -f "$f" "$f.bak" 2>/dev/null
      newid=""
      if command -v python3 >/dev/null 2>&1; then
        newid=$(python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null)
      fi
      [ -z "$newid" ] && newid=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c32)
      [ -z "$newid" ] && newid=$(date +%s%N)
      printf '%s\n' "$newid" > "$f" && echo "  重置: $f -> $newid"
    done
    # 2) JSON 里的 telemetry.* / device 键
    for j in $(find "$data" -maxdepth 6 -type f -name '*.json' 2>/dev/null); do
      if grep -qiE 'telemetry|devdeviceid|machineid|sqmid' "$j" 2>/dev/null; then
        cp -f "$j" "$j.bak" 2>/dev/null
        if command -v python3 >/dev/null 2>&1; then
          python3 - "$j" <<'PY' 2>/dev/null && echo "  重置 telemetry: $j"
import sys, json, uuid, secrets
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    sys.exit(1)
changed = False
for k in list(d.keys()):
    kl = k.lower()
    if 'telemetry' in kl or 'devdeviceid' in kl or 'machineid' in kl or 'sqmid' in kl:
        if 'sqm' in kl:
            d[k] = '{' + str(uuid.uuid4()).upper() + '}'
        elif 'machineid' in kl:
            d[k] = secrets.token_hex(32)
        else:
            d[k] = str(uuid.uuid4())
        changed = True
if isinstance(d.get('telemetry'), dict):
    d['telemetry']['machineId'] = secrets.token_hex(32)
    d['telemetry']['devDeviceId'] = str(uuid.uuid4())
    d['telemetry']['sqmId'] = '{' + str(uuid.uuid4()).upper() + '}'
    changed = True
json.dump(d, open(p, 'w'), indent=2)
sys.exit(0 if changed else 3)
PY
        else
          echo "  (无 python3，跳过 JSON 重置: $j)"
        fi
      fi
    done
    # 3) 清登录凭证
    for c in $(find "$data" -maxdepth 5 -type f 2>/dev/null | grep -iE 'cookies$|cookies-journal$'); do
      echo "  删除凭证: $c"
      rm -f "$c"
    done
  done
  echo "完成。重开 Trae 再登录。若仍受限 => device id 在 Keychain/服务端，跑 $0 keychain 或见文末说明。"
}

cmd_keychain() {
  echo "=== Keychain 探测 ==="
  echo "Keychain 目录: $KEYCHAIN_DIR"
  [ -d "$KEYCHAIN_DIR" ] && ls -la "$KEYCHAIN_DIR" 2>/dev/null | head -20 || echo "  (无此目录或未授权)"

  echo
  echo "--- 方案 A: keychaindumper（越狱工具，需已安装）---"
  kd=""
  for cand in /usr/sbin/keychaindumper /usr/bin/keychaindumper "$ROOT_HINT/keychaindumper" \
              /var/jb/usr/sbin/keychaindumper; do
    [ -x "$cand" ] && { kd="$cand"; break; }
  done
  if [ -n "$kd" ]; then
    echo "找到 keychaindumper: $kd"
    echo "  运行(需密码/自动):  $kd -d \"$KEYCHAIN_DIR\""
    echo "  然后 grep 与 Trae 相关的 service/identifier:"
    echo "  $kd -d \"$KEYCHAIN_DIR\" | grep -iE 'trae|icube|machine|device|uuid'"
    echo "把输出发给我，我据此写针对性重置。"
  else
    echo "  未安装 keychaindumper。安装方式（二选一）:"
    echo "   · Cydia/Sileo 源搜 'keychain dumper' 安装"
    echo "   · Theos:  apt 安装 或 下载二进制放 /usr/sbin/"
    echo "  Keychain 里的条目以 service/identifier 键形式存在，device id 通常挂在"
    echo "  某个 service(如 com.*.icube / Trae) 下。dump 后 grep trae/icube 定位。"
  fi

  echo
  echo "--- 方案 B: sqlite 直接读 Keychain 数据库（较新 iOS 加密，需 passcode）---"
  kc=$(find "$KEYCHAIN_DIR" -name 'mobilekeychain*' 2>/dev/null | head -1)
  if [ -n "$kc" ] && command -v sqlite3 >/dev/null 2>&1; then
    echo "Keychain DB: $kc"
    echo "  sqlite3 \"$kc\" 'select service, account, value_data from generic_password;'" \
      | grep -iE 'trae|icube|machine|device|uuid' || echo "  (未匹配或 DB 已加密)"
  else
    echo "  未找到可读的 Keychain DB（新版 iOS 的 Keychain 用 device key 加密，越狱终端难直接读，需用方案 A 的 dumper）。"
  fi
}

cmd_restore() {
  for line in $(find_trae); do
    data=$(echo "$line" | cut -d'|' -f3)
    [ -z "$data" ] && continue
    for b in $(find "$data" -maxdepth 6 -type f -name '*.bak' 2>/dev/null); do
      orig="${b%.bak}"
      cp -f "$b" "$orig" 2>/dev/null && echo "  恢复: $orig"
    done
  done
  echo "（Keychain 未做备份，无法通过此命令恢复；Keychain 修改请用 keychaindumper 的写回功能。）"
}

# 文末：本地无法改的情况
note_limits() {
  cat <<'EOF'

================ 本地无法改动的情形 ================
· IDFV (identifierForVendor): 系统生成，卸载该开发者全部 App 或 抹机 才变，改不了。
· 服务端账号绑定: 登录设备由 Trae 服务端按 Apple 账号/推送 token 核定，本地文件改不动，
  只能: 在 Trae 内「退出该设备」/ 联系官方 / 换 Apple 账号。
· 试用版「次数限制、次日解除」: 这是服务端 429 额度/风控，本地工具无效，次日自动重置。
EOF
}

case "${1:-probe}" in
  probe)    cmd_probe; note_limits ;;
  reset)    cmd_reset ;;
  keychain) cmd_keychain ;;
  restore)  cmd_restore ;;
  all)      cmd_probe; echo; echo ">>> 现在执行 reset"; cmd_reset ;;
  *) echo "用法: sh trae_cli.sh [probe|reset|keychain|restore|all]"; exit 2 ;;
esac
