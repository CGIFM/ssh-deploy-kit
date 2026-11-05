#!/bin/bash
# ============================================================
# SSHD Bridge Kit - 控制端诊断（macOS / Linux）
# 用法：./doctor.sh <别名>
#       ./doctor.sh -t <主机> [-u 账号] [-p 端口] [-i 私钥]
# ============================================================
set -u

ALIAS=""
TARGET=""
USER_ARG=""
PORT=22
KEY=""
TIMEOUT=4
NO_AUTH=0

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target) TARGET="${2:-}"; shift 2 ;;
    -u|--user) USER_ARG="${2:-}"; shift 2 ;;
    -p|--port) PORT="${2:-22}"; shift 2 ;;
    -i|--key) KEY="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-4}"; shift 2 ;;
    --no-auth) NO_AUTH=1; shift ;;
    -h|--help)
      echo "用法：$0 <别名> | $0 -t <主机> [-u 账号] [-p 端口] [-i 私钥]"
      exit 0 ;;
    -*) echo "未知参数：$1"; exit 2 ;;
    *) ALIAS="$1"; shift ;;
  esac
done

if [ -z "$ALIAS" ] && [ -z "$TARGET" ]; then
  echo "用法：$0 <别名> | $0 -t <主机> [-u 账号] [-p 端口] [-i 私钥]"
  exit 2
fi

if [ -n "$ALIAS" ]; then
  G=$(ssh -G "$ALIAS" 2>/dev/null) || { echo "ssh -G $ALIAS 失败"; exit 2; }
  TARGET=$(printf '%s\n' "$G" | awk '$1=="hostname"{print $2; exit}')
  [ -z "$USER_ARG" ] && USER_ARG=$(printf '%s\n' "$G" | awk '$1=="user"{print $2; exit}')
  P=$(printf '%s\n' "$G" | awk '$1=="port"{print $2; exit}')
  [ -n "$P" ] && PORT="$P"
  [ -z "$KEY" ] && KEY=$(printf '%s\n' "$G" | awk '$1=="identityfile"{print $2; exit}')
fi
[ -z "$USER_ARG" ] && USER_ARG=$(whoami)

echo ''
echo '=== SSHD Bridge Kit 诊断 ==='
[ -n "$ALIAS" ] && echo "  别名    : $ALIAS"
echo "  目标    : $USER_ARG@$TARGET:$PORT"
[ -n "$KEY" ] && echo "  私钥    : $KEY"
echo ''

# ---------- 本机网段 ----------
echo '[1] 本机网段'
LOCAL_NETS=""
if command -v ip >/dev/null 2>&1; then
  LOCAL_NETS=$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /\./ {print $2" "$4}')
else
  LOCAL_NETS=$(ifconfig 2>/dev/null | awk '
    function hex2dec(h,  i,c,d,v){ h=tolower(h); sub(/^0x/,"",h); v=0
      for(i=1;i<=length(h);i++){ c=substr(h,i,1); d=index("0123456789abcdef",c)-1; v=v*16+d } return v }
    function mask_prefix(v,  b,p,t){ p=0; t=2^31
      for(b=31;b>=0;b--){ if(v>=t){p++; v-=t} else break; t/=2 } return p }
    /^[a-zA-Z0-9_.-]+:/{ifc=$1; sub(":","",ifc)}
    $1=="inet" && $2!="127.0.0.1" && $2!~/^169\.254\./ {
      if ($4 ~ /^0x/) { p=mask_prefix(hex2dec($4)); print ifc" "$2"/"p }
    }')
fi

if [ -z "$LOCAL_NETS" ]; then
  echo '    [!] 读不到本机网卡信息'
else
  printf '%s\n' "$LOCAL_NETS" | while read -r ifc cidr; do
    echo "    $ifc  $cidr"
  done
fi

SAME=0
if printf '%s' "$TARGET" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  SAME=$(printf '%s\n' "$LOCAL_NETS" | awk -v tip="$TARGET" '
    function ip2int(s,  a){split(s,a,"."); return a[1]*16777216+a[2]*65536+a[3]*256+a[4]}
    {
      split($2, x, "/"); lip=x[1]; p=x[2]+0
      if (p<=0 || p>32) next
      size = 2^(32-p)
      if (int(ip2int(lip)/size) == int(ip2int(tip)/size)) { print "1"; exit }
    }')
  if [ "$SAME" = "1" ]; then
    echo "    [OK] 目标 $TARGET 与本机某个网段相同"
  else
    echo "    [!]  目标 $TARGET 不在本机任何直连网段（可能走 VPN/跳板/路由）"
  fi
fi

FAKE=0
case "$TARGET" in
  198.18.*|198.19.*)
    echo '    [X] 目标是 198.18/15（Clash fake-ip），不能作为连通证据'
    FAKE=1 ;;
esac

# ---------- 真握手 ----------
echo ''
echo '[2] 端口与握手'
BANNER=""
if (exec 3<>"/dev/tcp/$TARGET/$PORT") 2>/dev/null; then
  exec 3<>"/dev/tcp/$TARGET/$PORT" 2>/dev/null
  IFS= read -r -t "$TIMEOUT" BANNER <&3 || BANNER=""
  exec 3<&- 2>/dev/null
fi
case "$BANNER" in
  SSH-*) echo "    [OK] 真实 SSH 握手：$BANNER" ;;
  *)
    echo '    [X] 没有 SSH 握手（TCP 通不等于 SSH 通）'
    echo '        部分 VPN / 零信任网关 会对任意端口回 SYN-ACK，必须读到 SSH- 开头才算通。'
    ;;
esac

# ---------- 公钥登录 ----------
AUTH_RC=-1
if [ "$NO_AUTH" -eq 0 ] && [ -n "$BANNER" ]; then
  echo ''
  echo '[3] 公钥登录'
  AUTH_ARGS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
  [ -n "$KEY" ] && AUTH_ARGS+=(-i "$KEY")
  if ssh "${AUTH_ARGS[@]}" -p "$PORT" "$USER_ARG@$TARGET" 'echo SSHD_BRIDGE_OK' 2>/tmp/sshd-bridge-doctor.err | grep -q SSHD_BRIDGE_OK; then
    AUTH_RC=0
    echo '    [OK] 公钥登录成功'
  else
    AUTH_RC=1
    echo '    [X] 公钥登录失败'
    sed 's/^/        /' /tmp/sshd-bridge-doctor.err 2>/dev/null | head -5
    echo '        检查：公钥是否写入正确账号、authorized_keys 权限、账号是否允许登录。'
  fi
fi

# ---------- 结论 ----------
echo ''
echo '=== 结论 ==='
if [ "$FAKE" = "1" ]; then
  echo '  诊断：fake-ip 干扰，先用真实 IP 复测。'
  RC=2
elif [ -z "$BANNER" ]; then
  echo '  诊断：网络/服务层未通过。按顺序查 sshd 状态 → 防火墙 → 端口 → 假通设备。'
  RC=2
elif [ "$AUTH_RC" = "1" ]; then
  echo '  诊断：SSH 服务正常，公钥登录失败。问题在账号/密钥/权限。'
  RC=1
else
  echo '  诊断：全链路正常。'
  RC=0
fi
echo ''
exit "$RC"
