#!/bin/bash
# ============================================================
# SSHD Bridge Kit - macOS 一键部署
# 适用：macOS 11+
# 默认：开启远程登录 + 写入公钥 + 保留密码登录
# 收紧：确认控制端能用公钥登录后，运行 harden-ssh.sh
# ============================================================
set -u

KIT_VERSION="v1.0.0"
HERE=$(cd "$(dirname "$0")" && pwd)
SSHD=/usr/sbin/sshd
SSH_CFG=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="$DROPIN_DIR/100-sshd-bridge-kit.conf"
PORT=22
TARGET_USER=""
DO_KEY=1
DO_HARDEN=0
DO_FIREWALL=1
CHECK_ONLY=0
KEY_FILE=""
RESULT=""

usage() {
  cat <<'EOF'
用法：sudo bash install-sshd.sh [选项]

  --user NAME       允许远程登录的账号（默认：当前桌面用户）
  --key-file PATH   控制端公钥（默认：../keys/*.pub，取第一把）
  --no-key          不写公钥，只开 SSH
  --harden          同时关闭密码登录（要求公钥已写入）
  --no-firewall     不修改 macOS 应用防火墙
  --check           只体检，不修改任何配置
  -h, --help        显示帮助

说明：
  默认保留密码登录。请先用控制端确认公钥能登录，再运行 harden-ssh.sh。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --key-file=*) KEY_FILE="${1#*=}"; shift ;;
    --no-key) DO_KEY=0; shift ;;
    --harden) DO_HARDEN=1; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1"; usage; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "此脚本仅用于 macOS。Windows 用 windows/install.cmd；Linux 用 linux/install-sshd.sh。"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "需要管理员权限，正在请求 sudo（请输入本机登录密码）..."
  exec sudo -- bash "$0" "$@"
fi

if [ -z "$TARGET_USER" ]; then
  TARGET_USER=$(stat -f %Su /dev/console 2>/dev/null || true)
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="${SUDO_USER:-}"
  fi
  [ -z "$TARGET_USER" ] && TARGET_USER=$(id -un)
fi

if ! dscl . -read "/Users/$TARGET_USER" >/dev/null 2>&1; then
  echo "找不到账号：$TARGET_USER"
  exit 1
fi

HOME_T=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "$HOME_T" ] && HOME_T=$(eval echo "~$TARGET_USER")
HOSTN=$(scutil --get ComputerName 2>/dev/null || hostname)
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo unknown)
STAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG="$HERE/安装日志.txt"

# 没指定公钥时，自动找套件里的 keys/*.pub
if [ -z "$KEY_FILE" ] && [ "$DO_KEY" -eq 1 ]; then
  for d in "$HERE/keys" "$HERE/../keys"; do
    if [ -d "$d" ]; then
      KEY_FILE=$(find "$d" -maxdepth 1 -name '*.pub' -type f 2>/dev/null | head -1)
      [ -n "$KEY_FILE" ] && break
    fi
  done
fi

TOTAL=7
START_TS=$(date +%s)
CUR_STEP=""
FAILS=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '      [OK] %s\n' "$*"; }
warn() { printf '      [!]  %s\n' "$*"; }
dim()  { printf '      %s\n' "$*"; }
fail() { warn "$*"; FAILS=$((FAILS+1)); }
step() {
  CUR_STEP="$2"
  NOW=$(date +%s); EL=$((NOW-START_TS))
  BAR=""; i=1
  while [ $i -le 20 ]; do
    if [ $((i*TOTAL)) -le $(( $1*20 )) ]; then BAR="${BAR}#"; else BAR="${BAR}."; fi
    i=$((i+1))
  done
  printf '\n  [%s]  %s/%s   已用 %ss\n' "$BAR" "$1" "$TOTAL" "$EL"
  printf '  >> %s\n' "$2"
}

banner_test() {
  local host="$1" port="$2" line=""
  exec 3<>"/dev/tcp/$host/$port" 2>/dev/null || return 1
  IFS= read -r -t 5 line <&3 || { exec 3<&- 2>/dev/null; return 1; }
  exec 3<&- 2>/dev/null
  case "$line" in
    SSH-*) printf '%s\n' "$line"; return 0 ;;
    *) return 1 ;;
  esac
}

list_ips() {
  ifconfig -a 2>/dev/null | awk '
    /^[a-zA-Z0-9_.-]+:/ { iface=$1; sub(":","",iface); next }
    $1=="inet" && $2!="127.0.0.1" { print "      " iface "  " $2 }
  '
}

manifest_write() {
  local path="$1"
  {
    printf '=== SSHD Bridge Kit macOS 部署结果（%s） ===\n' "$KIT_VERSION"
    printf '结论      : %s\n' "$2"
    printf '时间      : %s\n' "$STAMP"
    printf '电脑名    : %s\n' "$HOSTN"
    printf 'macOS     : %s\n' "$MACOS_VER"
    printf '登录账号  : %s\n' "$TARGET_USER"
    printf 'sshd 握手 : %s\n' "${BANNER:-未通过}"
    printf '配置文件  : %s\n' "$DROPIN"
    printf '备份      : %s\n' "${BAK:-无}"
    printf '\n--- 生效配置 ---\n%s\n' "${EFFECTIVE:-无输出}"
    printf '\n--- 网络 ---\n'
    list_ips
    printf '默认网关  : %s\n' "${GW:-未知}"
    printf '\n--- 从控制端登录 ---\n'
    printf 'ssh %s@%s\n' "$TARGET_USER" "${IP_FIRST:-<本机IP>}"
    printf '\n说明：默认仍允许密码登录；确认公钥可用后再运行 sudo bash harden-ssh.sh。\n'
  } > "$path"
}

printf '\n============================================================\n'
printf '  SSHD Bridge Kit  %s（macOS）\n' "$KIT_VERSION"
printf '  本机：%s  macOS %s  时间：%s\n' "$HOSTN" "$MACOS_VER" "$STAMP"
printf '  登录账号：%s\n' "$TARGET_USER"
printf '  模式：%s\n' "$([ "$CHECK_ONLY" -eq 1 ] && echo '仅体检（不修改）' || echo '安装 / 修复')"
printf '============================================================\n'

if [ "$DO_HARDEN" -eq 1 ] && [ "$DO_KEY" -eq 0 ]; then
  say '错误：--harden 与 --no-key 不能同时使用。'
  exit 2
fi

# ---------- 1. 远程登录 ----------
step 1 '开启远程登录（Remote Login / sshd）'
if [ "$CHECK_ONLY" -eq 0 ]; then
  /usr/sbin/systemsetup -setremotelogin on >/dev/null 2>&1 || true
  if ! banner_test 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    /bin/launchctl enable system/com.openssh.sshd >/dev/null 2>&1 || true
    /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
  fi
fi
BANNER=""
i=0
while [ $i -lt 15 ]; do
  BANNER=$(banner_test 127.0.0.1 "$PORT" 2>/dev/null || true)
  [ -n "$BANNER" ] && break
  i=$((i+1)); sleep 1
done
if [ -n "$BANNER" ]; then
  ok "SSH 已启动：$BANNER"
else
  fail '22 端口没有返回 SSH- banner'
  warn 'macOS 13+ 需要给终端「完全磁盘访问权限」，再打开 系统设置 → 通用 → 共享 → 远程登录'
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  step 2 '体检：公钥与配置'
  for f in "$HOME_T/.ssh/authorized_keys" "$DROPIN"; do
    if [ -e "$f" ]; then ok "存在：$f"; else warn "不存在：$f"; fi
  done
  EFFECTIVE=$("$SSHD" -T 2>/dev/null | grep -E '^(port|passwordauthentication|pubkeyauthentication|authenticationmethods) ' || true)
  [ -n "$EFFECTIVE" ] && ok "$(printf '%s' "$EFFECTIVE" | tr '\n' ' ')" || warn 'sshd -T 无输出'
  exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
fi

# ---------- 2. 写入公钥 ----------
step 2 '写入控制端公钥'
KEY_OK=0
if [ "$DO_KEY" -eq 1 ]; then
  if [ -z "$KEY_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    warn '没有找到公钥文件；本次只能密码登录'
  else
    # 关键：Windows 拷来的 .pub 可能带 CRLF，必须清掉
    KEY_LINE=$(tr -d '\r' < "$KEY_FILE" | grep -Ev '^\s*(#|$)' | head -1)
    KEY_BODY=$(printf '%s' "$KEY_LINE" | awk '{print $2}')
    if [ -z "$KEY_BODY" ]; then
      warn "公钥格式不对：$KEY_FILE"
    else
      mkdir -p "$HOME_T/.ssh"
      chmod 700 "$HOME_T/.ssh"
      chown "$TARGET_USER" "$HOME_T/.ssh"
      touch "$HOME_T/.ssh/authorized_keys"
      chmod 600 "$HOME_T/.ssh/authorized_keys"
      chown "$TARGET_USER" "$HOME_T/.ssh/authorized_keys"
      if grep -qF -- "$KEY_BODY" "$HOME_T/.ssh/authorized_keys"; then
        ok "公钥已存在：$HOME_T/.ssh/authorized_keys"
      else
        [ -s "$HOME_T/.ssh/authorized_keys" ] && printf '\n' >> "$HOME_T/.ssh/authorized_keys"
        printf '%s\n' "$KEY_LINE" >> "$HOME_T/.ssh/authorized_keys"
        ok "已写入公钥：$HOME_T/.ssh/authorized_keys"
      fi
      if grep -qF -- "$KEY_BODY" "$HOME_T/.ssh/authorized_keys"; then
        KEY_OK=1
      else
        fail '公钥回读失败'
      fi
      dim "权限：$(stat -f '%Lp %Su' "$HOME_T/.ssh/authorized_keys" 2>/dev/null)（应为 600 且属主 $TARGET_USER）"
      if [ -n "$(find "$HOME_T" -maxdepth 0 -perm -002 2>/dev/null)" ]; then
        warn "主目录对其他人可写，sshd StrictModes 可能拒绝公钥：$HOME_T"
      fi
    fi
  fi
else
  ok '已指定 --no-key，跳过'
fi

if [ "$DO_HARDEN" -eq 1 ] && [ "$KEY_OK" -ne 1 ]; then
  say '拒绝执行 --harden：公钥没有写入成功，关闭密码会把自己锁在门外。'
  exit 2
fi

# ---------- 3. 配置 sshd ----------
step 3 '配置 sshd（托管段，先备份）'
mkdir -p "$DROPIN_DIR"
BAK="$SSH_CFG.bak-sshd-bridge-$(date +%Y%m%d-%H%M%S)"
cp -p "$SSH_CFG" "$BAK" 2>/dev/null || true

INCLUDE_ADDED=0
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSH_CFG"; then
  TMP=$(mktemp -t sshd-bridge) || exit 1
  { printf 'Include /etc/ssh/sshd_config.d/*\n\n'; cat "$SSH_CFG"; } > "$TMP"
  cp -p "$TMP" "$SSH_CFG"
  rm -f "$TMP"
  INCLUDE_ADDED=1
  ok '主配置已包含 sshd_config.d'
fi

PASS_AUTH="yes"
[ "$DO_HARDEN" -eq 1 ] && PASS_AUTH="no"
{
  printf '# === managed by sshd-bridge-kit %s ===\n' "$KIT_VERSION"
  printf 'PubkeyAuthentication yes\n'
  printf 'PasswordAuthentication %s\n' "$PASS_AUTH"
  printf 'PermitRootLogin no\n'
  if [ "$DO_HARDEN" -eq 1 ]; then
    printf 'AuthenticationMethods publickey\n'
    printf 'KbdInteractiveAuthentication no\n'
  fi
  printf '# === end managed by sshd-bridge-kit ===\n'
} > "$DROPIN"
chmod 644 "$DROPIN"
ok "已写入 $DROPIN（密码登录：$PASS_AUTH）"

if ! "$SSHD" -t 2>"$HERE/sshd-config-check.err"; then
  warn 'sshd_config 校验失败，正在回滚：'
  sed 's/^/      /' "$HERE/sshd-config-check.err" 2>/dev/null || true
  rm -f "$DROPIN"
  cp -p "$BAK" "$SSH_CFG"
  fail '配置校验失败，已回滚'
else
  ok 'sshd_config 校验通过'
fi

# ---------- 4. 防火墙 ----------
step 4 '检查 macOS 防火墙'
if [ "$DO_FIREWALL" -eq 0 ]; then
  ok '已指定 --no-firewall，跳过'
else
  FW=/usr/libexec/ApplicationFirewall/socketfilterfw
  if [ -x "$FW" ]; then
    FW_STATE=$("$FW" --getglobalstate 2>/dev/null || echo unknown)
    case "$FW_STATE" in
      *enabled*)
        "$FW" --add /usr/sbin/sshd >/dev/null 2>&1 || true
        "$FW" --unblockapp /usr/sbin/sshd >/dev/null 2>&1 || true
        ok '应用防火墙已开启，已放行 /usr/sbin/sshd'
        ;;
      *) ok "应用防火墙未开启：$FW_STATE" ;;
    esac
  else
    ok '找不到 socketfilterfw，跳过'
  fi
fi

# ---------- 5. 重启并验证 ----------
step 5 '重启 sshd 并读取生效配置'
/bin/launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || {
  /bin/launchctl stop system/com.openssh.sshd >/dev/null 2>&1 || true
  /bin/launchctl start system/com.openssh.sshd >/dev/null 2>&1 || true
}
sleep 2
BANNER=""
i=0
while [ $i -lt 10 ]; do
  BANNER=$(banner_test 127.0.0.1 "$PORT" 2>/dev/null || true)
  [ -n "$BANNER" ] && break
  i=$((i+1)); sleep 1
done
if [ -n "$BANNER" ]; then ok "回环握手正常：$BANNER"; else fail '回环握手失败'; fi

EFFECTIVE=$("$SSHD" -T 2>/dev/null | grep -E '^(port|passwordauthentication|pubkeyauthentication|authenticationmethods|permitrootlogin) ' || true)
if [ -n "$EFFECTIVE" ]; then
  printf '%s\n' "$EFFECTIVE" | while IFS= read -r l; do ok "$l"; done
  EFF_PASS=$(printf '%s\n' "$EFFECTIVE" | awk '$1=="passwordauthentication"{print $2; exit}')
  if [ "$DO_HARDEN" -eq 1 ] && [ "$EFF_PASS" != "no" ]; then
    fail "生效配置仍是 PasswordAuthentication=${EFF_PASS:-未知}"
    warn '检查 /etc/ssh/sshd_config 顶部是否还有同名指令'
  fi
else
  warn 'sshd -T 没有输出（可能受 SIP/MDM 限制）'
fi

# ---------- 6. 网络 ----------
step 6 '本机网络信息'
list_ips
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
[ -n "$GW" ] && ok "默认网关：$GW"

# ---------- 7. 汇总 ----------
step 7 '汇总'
IP_FIRST=$(ifconfig -a 2>/dev/null | awk '/^[a-zA-Z0-9_.-]+:/{i=$1} $1=="inet" && $2!="127.0.0.1" && $2!~/^169\.254\./ {print $2; exit}')
RESULT="$HERE/部署结果.txt"
CONCLUSION="成功，SSH 已通"
[ "$FAILS" -ne 0 ] && CONCLUSION="未完全成功（$FAILS 项待处理）"
manifest_write "$RESULT" "$CONCLUSION"
if [ -d "$HOME_T/Desktop" ]; then
  cp "$RESULT" "$HOME_T/Desktop/部署结果.txt" 2>/dev/null || true
  chown "$TARGET_USER" "$HOME_T/Desktop/部署结果.txt" 2>/dev/null || true
fi

printf '\n============================================================\n'
if [ "$FAILS" -eq 0 ]; then
  printf '  部署完成 —— SSH 服务已启动，回环握手正常\n'
else
  printf '  部署未完全成功 —— 见上面的 [!] 项\n'
fi
printf '============================================================\n'
printf '  登录账号 : %s\n' "$TARGET_USER"
printf '  登录命令 : ssh %s@%s\n' "$TARGET_USER" "${IP_FIRST:-<本机IP>}"
printf '  密码登录 : %s\n' "$PASS_AUTH"
printf '  配置备份 : %s\n' "$BAK"
printf '  结果文件 : %s\n' "$RESULT"
printf '  耗时     : %s 秒\n' "$(( $(date +%s) - START_TS ))"
printf '============================================================\n'
[ "$PASS_AUTH" = "yes" ] && printf '  下一步：确认公钥登录成功后，运行 sudo bash harden-ssh.sh\n'
printf '\n'

exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
