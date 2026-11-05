#!/bin/bash
# ============================================================
# SSHD Bridge Kit - macOS 收紧密码登录
# 前置：install-sshd.sh 已成功写入公钥，且控制端已用公钥登录成功
# 用法：sudo bash harden-ssh.sh [--undo]
# ============================================================
set -u

KIT_VERSION="v1.0.0"
SSHD=/usr/sbin/sshd
SSH_CFG=/etc/ssh/sshd_config
DROPIN=/etc/ssh/sshd_config.d/100-sshd-bridge-kit.conf
UNDO=0

case "${1:-}" in
  --undo) UNDO=1 ;;
  -h|--help)
    echo "用法：sudo bash harden-ssh.sh [--undo]"
    echo "  --undo  恢复密码登录"
    exit 0 ;;
  '') ;;
  *) echo "未知参数：$1"; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo '此脚本仅用于 macOS。'
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-$(stat -f %Su /dev/console 2>/dev/null)}"
HOME_T=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "$HOME_T" ] && HOME_T=$(eval echo "~$TARGET_USER")
KEYS="$HOME_T/.ssh/authorized_keys"

echo ''
echo "=== SSHD Bridge Kit 收紧配置（$KIT_VERSION）==="
echo "账号：$TARGET_USER"
echo ''

if [ "$UNDO" -eq 0 ]; then
  if [ ! -s "$KEYS" ]; then
    echo "[X] $KEYS 不存在或为空。"
    echo "    先运行 install-sshd.sh 写入公钥，并确认控制端能登录，再来收紧。"
    exit 2
  fi
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSH_CFG"; then
    echo '[X] 主配置没有 Include sshd_config.d，先运行 install-sshd.sh。'
    exit 2
  fi
fi

mkdir -p /etc/ssh/sshd_config.d
BAK="$SSH_CFG.bak-sshd-bridge-$(date +%Y%m%d-%H%M%S)"
cp -p "$SSH_CFG" "$BAK"

if [ "$UNDO" -eq 1 ]; then
  PASS_AUTH="yes"
  echo '  恢复密码登录...'
else
  PASS_AUTH="no"
  echo '  关闭密码登录（仅公钥）...'
fi

{
  printf '# === managed by sshd-bridge-kit %s ===\n' "$KIT_VERSION"
  printf 'PubkeyAuthentication yes\n'
  printf 'PasswordAuthentication %s\n' "$PASS_AUTH"
  printf 'PermitRootLogin no\n'
  if [ "$UNDO" -eq 0 ]; then
    printf 'AuthenticationMethods publickey\n'
    printf 'KbdInteractiveAuthentication no\n'
  fi
  printf '# === end managed by sshd-bridge-kit ===\n'
} > "$DROPIN"
chmod 644 "$DROPIN"

if ! "$SSHD" -t 2>/tmp/sshd-bridge-check.err; then
  echo '[X] 配置校验失败，已回滚：'
  sed 's/^/    /' /tmp/sshd-bridge-check.err 2>/dev/null || true
  rm -f "$DROPIN"
  cp -p "$BAK" "$SSH_CFG"
  exit 1
fi

/bin/launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
sleep 2

EFF=$("$SSHD" -T 2>/dev/null | grep -E '^(passwordauthentication|pubkeyauthentication|authenticationmethods) ' || true)
echo ''
echo '  生效配置：'
printf '%s\n' "$EFF" | sed 's/^/    /'
echo ''

EFF_PASS=$(printf '%s\n' "$EFF" | awk '$1=="passwordauthentication"{print $2; exit}')
if [ "$PASS_AUTH" = "no" ] && [ "$EFF_PASS" != "no" ]; then
  echo '[X] 密码登录没有真正关闭，检查 sshd_config 顶部是否有同名指令。'
  exit 1
fi

echo '完成。配置备份：'
echo "  $BAK"
echo ''
echo '验证命令（在控制端执行，另开一个窗口，别关掉当前连接）：'
echo "  ssh $TARGET_USER@<本机IP>"
echo ''
