#!/bin/bash
# ============================================================
# SSHD Bridge Kit - Linux 一键部署
# 适用：Debian/Ubuntu、RHEL/CentOS/Rocky/Alma、Fedora、Alpine、Arch
# 默认：安装/启动 sshd + 写入公钥 + 保留密码登录
# 收紧：确认公钥登录成功后加 --harden
# ============================================================
set -u

KIT_VERSION="v1.0.0"
HERE=$(cd "$(dirname "$0")" && pwd)
SSHD=""
SSH_CFG=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
# 00- 前缀：必须排在 cloud-init 的 50-cloud-init.conf 之前
DROPIN="$DROPIN_DIR/00-sshd-bridge-kit.conf"
PORT=22
TARGET_USER=""
KEY_FILE=""
DO_KEY=1
DO_HARDEN=0
DO_FIREWALL=1
CHECK_ONLY=0
FAILS=0

usage() {
  cat <<'EOF'
用法：sudo bash install-sshd.sh [选项]

  --user NAME       写公钥的账号（默认：sudo 调用者，否则 root）
  --key-file PATH   控制端公钥（默认：../keys/*.pub，取第一把）
  --port N          SSH 端口（默认 22）
  --no-key          不写公钥，只开 SSH
  --harden          关闭密码登录（要求公钥已写入）
  --no-firewall     不配置 ufw/firewalld
  --check           只体检，不修改
  -h, --help        显示帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --key-file=*) KEY_FILE="${1#*=}"; shift ;;
    --port) PORT="${2:-22}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --no-key) DO_KEY=0; shift ;;
    --harden) DO_HARDEN=1; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1"; usage; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '      [OK] %s\n' "$*"; }
warn() { printf '      [!]  %s\n' "$*"; }
dim()  { printf '      %s\n' "$*"; }
fail() { warn "$*"; FAILS=$((FAILS+1)); }

if [ "$(id -u)" -ne 0 ]; then
  echo '需要 root 权限，正在请求 sudo...'
  exec sudo -- bash "$0" "$@"
fi

if [ "$(uname -s)" != "Linux" ]; then
  echo '此脚本仅用于 Linux。'
  exit 1
fi

if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${SUDO_USER:-root}"
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "找不到账号：$TARGET_USER"
  exit 1
fi
HOME_T=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[ -z "$HOME_T" ] && HOME_T=$(eval echo "~$TARGET_USER")

if [ -z "$KEY_FILE" ] && [ "$DO_KEY" -eq 1 ]; then
  for d in "$HERE/keys" "$HERE/../keys"; do
    if [ -d "$d" ]; then
      KEY_FILE=$(find "$d" -maxdepth 1 -name '*.pub' -type f 2>/dev/null | head -1)
      [ -n "$KEY_FILE" ] && break
    fi
  done
fi

STAMP=$(date '+%Y-%m-%d %H:%M:%S')
START_TS=$(date +%s)
TOTAL=7

step() {
  local n="$1" text="$2"
  local el=$(( $(date +%s) - START_TS ))
  local bar="" i=1
  while [ $i -le 20 ]; do
    if [ $((i*TOTAL)) -le $(( n*20 )) ]; then bar="${bar}#"; else bar="${bar}."; fi
    i=$((i+1))
  done
  printf '\n  [%s]  %s/%s   已用 %ss\n' "$bar" "$n" "$TOTAL" "$el"
  printf '  >> %s\n' "$text"
}

banner_test() {
  local host="$1" port="$2" line=""
  if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
    exec 3<>"/dev/tcp/$host/$port" 2>/dev/null || return 1
    IFS= read -r -t 5 line <&3 || { exec 3<&- 2>/dev/null; return 1; }
    exec 3<&- 2>/dev/null
  elif command -v nc >/dev/null 2>&1; then
    line=$(nc -w 5 "$host" "$port" 2>/dev/null | head -1)
  elif command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    line=$(timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port; head -1 <&3" 2>/dev/null)
  else
    return 1
  fi
  case "$line" in
    SSH-*) printf '%s\n' "$line"; return 0 ;;
    *) return 1 ;;
  esac
}

resolve_sshd() {
  for p in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
    if [ -x "$p" ]; then SSHD="$p"; return 0; fi
  done
  if command -v sshd >/dev/null 2>&1; then SSHD=$(command -v sshd); return 0; fi
  return 1
}

pkg_install_openssh() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssh
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm openssh
  else
    return 1
  fi
}

service_unit() {
  for u in ssh.service sshd.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl list-unit-files "$u" | grep -q "$u"; then
      printf '%s' "$u"; return 0
    fi
  done
  return 1
}

restart_sshd() {
  if command -v systemctl >/dev/null 2>&1; then
    local u
    u=$(service_unit) || u=""
    if [ -n "$u" ]; then
      systemctl enable "$u" >/dev/null 2>&1 || true
      systemctl restart "$u" 2>/dev/null || systemctl start "$u"
      return $?
    fi
    if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
      systemctl enable ssh.socket >/dev/null 2>&1 || true
      systemctl restart ssh.socket 2>/dev/null || true
      return 0
    fi
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-update add sshd default >/dev/null 2>&1 || true
    rc-service sshd restart
    return $?
  fi
  return 1
}

printf '\n============================================================\n'
printf '  SSHD Bridge Kit  %s（Linux）\n' "$KIT_VERSION"
printf '  主机：%s  时间：%s\n' "$(hostname)" "$STAMP"
printf '  账号：%s  端口：%s\n' "$TARGET_USER" "$PORT"
printf '  模式：%s\n' "$([ "$CHECK_ONLY" -eq 1 ] && echo '仅体检（不修改）' || echo '安装 / 修复')"
printf '============================================================\n'

if [ "$DO_HARDEN" -eq 1 ] && [ "$DO_KEY" -eq 0 ]; then
  say '错误：--harden 与 --no-key 不能同时使用。'
  exit 2
fi

# ---------- 1. 安装 ----------
step 1 '检查 / 安装 OpenSSH Server'
if resolve_sshd; then
  ok "已安装：$SSHD（$($SSHD -V 2>&1 | head -1)）"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  fail '未安装 OpenSSH Server'
else
  dim '未安装，尝试用系统包管理器安装...'
  if pkg_install_openssh && resolve_sshd; then
    ok "安装完成：$SSHD"
  else
    fail '安装失败（可能无外网或仓库不可用）'
    warn '离线环境请准备 openssh-server 及依赖包，或从同版本机器复制 /etc/ssh 与二进制'
    exit 1
  fi
fi

# ---------- 2. 主机密钥 ----------
step 2 '准备主机密钥'
if [ "$CHECK_ONLY" -eq 0 ]; then
  if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    ssh-keygen -A
    ok '已生成主机密钥'
  else
    ok '主机密钥已存在'
  fi
fi

# ---------- 3. 写入公钥 ----------
step 3 '写入控制端公钥'
KEY_OK=0
AUTH_KEYS="$HOME_T/.ssh/authorized_keys"
if [ "$DO_KEY" -eq 1 ]; then
  if [ -z "$KEY_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    warn '没有找到公钥文件；本次只能密码登录'
  else
    KEY_LINE=$(tr -d '\r' < "$KEY_FILE" | grep -Ev '^\s*(#|$)' | head -1)
    KEY_BODY=$(printf '%s' "$KEY_LINE" | awk '{print $2}')
    if [ -z "$KEY_BODY" ]; then
      fail "公钥格式不对：$KEY_FILE"
    else
      mkdir -p "$HOME_T/.ssh"
      chmod 700 "$HOME_T/.ssh"
      chown "$TARGET_USER":"$TARGET_USER" "$HOME_T/.ssh"
      touch "$AUTH_KEYS"
      chmod 600 "$AUTH_KEYS"
      chown "$TARGET_USER":"$TARGET_USER" "$AUTH_KEYS"
      if grep -qF -- "$KEY_BODY" "$AUTH_KEYS"; then
        ok "公钥已存在：$AUTH_KEYS"
      else
        [ -s "$AUTH_KEYS" ] && printf '\n' >> "$AUTH_KEYS"
        printf '%s\n' "$KEY_LINE" >> "$AUTH_KEYS"
        ok "已写入公钥：$AUTH_KEYS"
      fi
      if grep -qF -- "$KEY_BODY" "$AUTH_KEYS"; then
        KEY_OK=1
      else
        fail '公钥回读失败'
      fi
      dim "权限：$(stat -c '%a %U' "$AUTH_KEYS" 2>/dev/null)（应为 600 且属主 $TARGET_USER）"
    fi
  fi
else
  ok '已指定 --no-key，跳过'
fi

if [ "$DO_HARDEN" -eq 1 ] && [ "$KEY_OK" -ne 1 ]; then
  say '拒绝执行 --harden：公钥没有写入成功，关闭密码会把自己锁在门外。'
  exit 2
fi

# ---------- 4. 配置 ----------
step 4 '写入 sshd 托管配置'
mkdir -p "$DROPIN_DIR"
BAK="$SSH_CFG.bak-sshd-bridge-$(date +%Y%m%d-%H%M%S)"
cp -p "$SSH_CFG" "$BAK" 2>/dev/null || true

INCLUDE_ADDED=0
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSH_CFG"; then
  TMP=$(mktemp) || exit 1
  { printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'; cat "$SSH_CFG"; } > "$TMP"
  cp -p "$TMP" "$SSH_CFG"
  rm -f "$TMP"
  INCLUDE_ADDED=1
  ok '主配置已包含 sshd_config.d'
fi

if [ -f "$DROPIN_DIR/50-cloud-init.conf" ]; then
  warn '检测到 50-cloud-init.conf；本套件用 00- 前缀，仍会优先生效'
fi

PASS_AUTH="yes"
[ "$DO_HARDEN" -eq 1 ] && PASS_AUTH="no"
{
  printf '# === managed by sshd-bridge-kit %s ===\n' "$KIT_VERSION"
  [ "$PORT" -ne 22 ] && printf 'Port %s\n' "$PORT"
  printf 'PubkeyAuthentication yes\n'
  printf 'PasswordAuthentication %s\n' "$PASS_AUTH"
  printf 'PermitRootLogin no\n'
  if [ "$DO_HARDEN" -eq 1 ]; then
    printf 'AuthenticationMethods publickey\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'ChallengeResponseAuthentication no\n'
  fi
  printf '# === end managed by sshd-bridge-kit ===\n'
} > "$DROPIN"
chmod 644 "$DROPIN"
ok "已写入 $DROPIN（密码登录：$PASS_AUTH）"

if ! "$SSHD" -t 2>"$HERE/sshd-config-check.err"; then
  warn '配置校验失败，已回滚：'
  sed 's/^/      /' "$HERE/sshd-config-check.err" 2>/dev/null || true
  rm -f "$DROPIN"
  cp -p "$BAK" "$SSH_CFG"
  fail '配置校验失败，已回滚'
else
  ok 'sshd_config 校验通过'
fi

# ---------- 5. 防火墙 / SELinux ----------
step 5 '防火墙与 SELinux'
if [ "$PORT" -ne 22 ] && command -v semanage >/dev/null 2>&1; then
  if semanage port -l 2>/dev/null | grep -q "ssh_port_t.*$PORT"; then
    ok "SELinux 已允许端口 $PORT"
  else
    semanage port -a -t ssh_port_t -p tcp "$PORT" 2>/dev/null || \
      semanage port -m -t ssh_port_t -p tcp "$PORT" 2>/dev/null || \
      warn "SELinux 端口标签设置失败，请手动 semanage port -a -t ssh_port_t -p tcp $PORT"
  fi
fi

if [ "$DO_FIREWALL" -eq 0 ]; then
  ok '已指定 --no-firewall，跳过'
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  for net in 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12 100.64.0.0/10; do
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$net port port=$PORT protocol=tcp accept" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "firewalld 已放行端口 $PORT（内网 + Tailscale）"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
  for net in 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12 100.64.0.0/10; do
    ufw allow from "$net" to any port "$PORT" proto tcp >/dev/null 2>&1 || true
  done
  ok "ufw 已放行端口 $PORT（内网 + Tailscale）"
else
  warn '没有检测到活动的 firewalld/ufw；如有其他防火墙，请自行放行'
fi

# ---------- 6. 启动 ----------
step 6 '启动 sshd 并验证'
if [ "$CHECK_ONLY" -eq 0 ]; then
  restart_sshd || { fail 'sshd 启动失败'; }
  sleep 2
fi

BANNER=""
i=0
while [ $i -lt 10 ]; do
  BANNER=$(banner_test 127.0.0.1 "$PORT" 2>/dev/null || true)
  [ -n "$BANNER" ] && break
  i=$((i+1)); sleep 1
done
if [ -n "$BANNER" ]; then ok "回环握手：$BANNER"; else fail '回环没有读到 SSH- banner'; fi

EFFECTIVE=$("$SSHD" -T 2>/dev/null | grep -E '^(port|passwordauthentication|pubkeyauthentication|authenticationmethods) ' || true)
if [ -n "$EFFECTIVE" ]; then
  printf '%s\n' "$EFFECTIVE" | while IFS= read -r l; do ok "$l"; done
else
  warn 'sshd -T 无输出'
fi

# ---------- 7. 汇总 ----------
step 7 '汇总'
IP_FIRST=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -Ev '^(127\.|169\.254\.)' | head -1)
RESULT="$HERE/部署结果.txt"
{
  printf '=== SSHD Bridge Kit Linux 部署结果（%s） ===\n' "$KIT_VERSION"
  printf '结论      : %s\n' "$([ "$FAILS" -eq 0 ] && echo '成功' || echo "未完全成功（$FAILS 项）")"
  printf '时间      : %s\n' "$STAMP"
  printf '主机      : %s\n' "$(hostname)"
  printf '用户      : %s\n' "$TARGET_USER"
  printf '端口      : %s\n' "$PORT"
  printf '密码登录  : %s\n' "$PASS_AUTH"
  printf 'SSH 握手  : %s\n' "${BANNER:-未通过}"
  printf '配置      : %s\n' "$DROPIN"
  printf '备份      : %s\n' "$BAK"
  printf '登录命令  : ssh %s@%s%s\n' "$TARGET_USER" "${IP_FIRST:-<本机IP>}" "$([ "$PORT" -ne 22 ] && echo " -p $PORT")"
  printf '\n--- 生效配置 ---\n%s\n' "${EFFECTIVE:-无输出}"
} > "$RESULT"

printf '\n============================================================\n'
if [ "$FAILS" -eq 0 ]; then printf '  部署完成 —— SSH 已启动，回环握手正常\n'
else printf '  部署未完全成功 —— 见上面的 [!] 项\n'; fi
printf '============================================================\n'
printf '  登录命令 : ssh %s@%s%s\n' "$TARGET_USER" "${IP_FIRST:-<本机IP>}" "$([ "$PORT" -ne 22 ] && echo " -p $PORT")"
printf '  密码登录 : %s\n' "$PASS_AUTH"
printf '  配置备份 : %s\n' "$BAK"
printf '  结果文件 : %s\n' "$RESULT"
printf '  耗时     : %s 秒\n' "$(( $(date +%s) - START_TS ))"
printf '============================================================\n'
[ "$PASS_AUTH" = "yes" ] && printf '  下一步：确认公钥登录成功后，加 --harden 重跑\n'
printf '\n'

exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
