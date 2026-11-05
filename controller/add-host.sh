#!/bin/bash
# ============================================================
# SSHD Bridge Kit - 控制端（macOS / Linux）
# 生成密钥 + 写入 ~/.ssh/config 别名 + 自动验证
# 用法：./add-host.sh <别名> <主机> [账号] [端口] [私钥路径] [跳板别名]
# ============================================================
set -u

ALIAS="${1:-}"
HOST="${2:-}"
USER_ARG="${3:-Administrator}"
PORT="${4:-22}"
KEY="${5:-$HOME/.ssh/id_ed25519_${ALIAS}}"
JUMP="${6:-}"
CFG="$HOME/.ssh/config"

if [ -z "$ALIAS" ] || [ -z "$HOST" ]; then
  echo "用法：$0 <别名> <主机> [账号] [端口] [私钥路径] [跳板别名]"
  exit 2
fi
case "$ALIAS" in
  *[!A-Za-z0-9._-]*) echo "别名只能包含字母、数字、点、下划线、连字符"; exit 2 ;;
esac

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ -f "$KEY" ]; then
  echo "  密钥已存在：$KEY"
else
  ssh-keygen -t ed25519 -f "$KEY" -N '' -C "$(whoami)@$(hostname)-$(date +%Y%m%d)" >/dev/null || exit 1
  echo "  已生成密钥：$KEY"
fi

PUB="$KEY.pub"
[ -f "$PUB" ] || { echo "找不到公钥：$PUB"; exit 1; }
echo "  公钥："
sed 's/^/    /' "$PUB"
echo "  指纹：$(ssh-keygen -lf "$PUB" 2>/dev/null)"

# 幂等替换同名 Host 块
if [ -f "$CFG" ]; then
  cp -p "$CFG" "$CFG.bak-sshd-bridge-$(date +%Y%m%d%H%M%S)"
  awk -v alias="$ALIAS" '
    BEGIN { skip=0 }
    /^[[:space:]]*Host[[:space:]]+/ {
      line=$0; sub(/^[[:space:]]*Host[[:space:]]+/, "", line)
      n=split(line, a, /[[:space:]]+/); skip=0
      for (i=1; i<=n; i++) if (a[i]==alias) skip=1
    }
    /^[[:space:]]*(Match|Include)[[:space:]]+/ { skip=0 }
    skip==0 { print }
  ' "$CFG" > "$CFG.tmp.$$" && mv "$CFG.tmp.$$" "$CFG"
fi

{
  printf '\nHost %s\n' "$ALIAS"
  printf '    HostName %s\n' "$HOST"
  printf '    Port %s\n' "$PORT"
  printf '    User %s\n' "$USER_ARG"
  printf '    IdentityFile %s\n' "$KEY"
  printf '    IdentitiesOnly yes\n'
  printf '    StrictHostKeyChecking accept-new\n'
  printf '    ServerAliveInterval 30\n'
  printf '    ServerAliveCountMax 3\n'
  [ -n "$JUMP" ] && printf '    ProxyJump %s\n' "$JUMP"
} >> "$CFG"
chmod 600 "$CFG"
echo "  已写入别名：$ALIAS -> $USER_ARG@$HOST:$PORT"

# 真握手
echo ''
BANNER=""
if (exec 3<>"/dev/tcp/$HOST/$PORT") 2>/dev/null; then
  exec 3<>"/dev/tcp/$HOST/$PORT" 2>/dev/null
  IFS= read -r -t 5 BANNER <&3 || BANNER=""
  exec 3<&- 2>/dev/null
fi
case "$BANNER" in
  SSH-*) echo "  [OK] 握手正常：$BANNER" ;;
  *)
    echo "  [X] 没有读到 SSH- banner。"
    echo "      目标机可能未装/未启动 sshd，或被防火墙拦截。"
    echo "      部署时带上这把公钥：$PUB"
    exit 2
    ;;
esac

# 公钥登录
AUTH_ARGS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -i "$KEY")
[ -n "$JUMP" ] && AUTH_ARGS+=(-J "$JUMP")
if ssh "${AUTH_ARGS[@]}" -p "$PORT" "$USER_ARG@$HOST" 'echo SSHD_BRIDGE_OK' 2>/tmp/sshd-bridge-auth.err | grep -q SSHD_BRIDGE_OK; then
  echo '  [OK] 公钥登录成功'
  echo ''
  echo "  以后直接用：ssh $ALIAS"
else
  echo '  [!] 握手正常，但公钥登录未通过。'
  echo "      把 $PUB 放到目标机后重跑安装脚本。"
  sed 's/^/      /' /tmp/sshd-bridge-auth.err 2>/dev/null | head -5
  exit 3
fi
