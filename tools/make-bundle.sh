#!/usr/bin/env bash
# ============================================================
# SSHD Bridge Kit - 生成单目标离线部署包（macOS / Linux 控制端）
# 用法：
#   ./make-bundle.sh windows ~/.ssh/id_ed25519_win-a.pub ./release
#   ./make-bundle.sh macos   ~/.ssh/id_ed25519_mac.pub
#   ./make-bundle.sh linux   ~/.ssh/id_ed25519_srv.pub
# ============================================================
set -euo pipefail

OS_KIND="${1:-}"
PUBKEY_FILE="${2:-}"
OUT_DIR="${3:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
STAMP="$(date +%Y%m%d)"
NAME="sshd-deploy-$OS_KIND-$STAMP"

case "$OS_KIND" in windows|macos|linux) ;; *)
  echo "用法：$0 {windows|macos|linux} [公钥文件] [输出目录]" >&2; exit 2 ;;
esac

[ -n "$OUT_DIR" ] || OUT_DIR="$ROOT/release"
mkdir -p "$OUT_DIR"
STAGE="$OUT_DIR/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

PUB_LINE=""
if [ -n "$PUBKEY_FILE" ]; then
  [ -f "$PUBKEY_FILE" ] || { echo "找不到公钥：$PUBKEY_FILE" >&2; exit 2; }
  PUB_LINE="$(tr -d '\r' < "$PUBKEY_FILE" | grep -Ev '^[[:space:]]*(#|$)' | head -1)"
  case "$PUB_LINE" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp*) ;;
    *) echo "公钥格式不合法，拒绝打包" >&2; exit 2 ;;
  esac
else
  echo "  [!] 没有提供公钥：部署后会保留密码登录"
fi

case "$OS_KIND" in
  windows)
    mkdir -p "$STAGE/windows/offline" "$STAGE/keys"
    cp "$ROOT/windows/install.cmd" "$ROOT/windows/setup-sshd.ps1" "$ROOT/windows/uninstall-sshd.ps1" "$STAGE/windows/"
    cp "$ROOT/windows/offline/README.md" "$STAGE/windows/offline/"
    [ -n "$PUB_LINE" ] && printf '%s\n' "$PUB_LINE" > "$STAGE/keys/id_bridge.pub"
    STEPS="1. 解压整个文件夹\n2. 右键 install.cmd → 以管理员身份运行\n3. 等待 “部署完成 —— SSH 服务已启动，真实握手正常”\n4. 把桌面 部署结果.txt 发回控制端\n5. 不能上网时：把 OpenSSH-Win64.msi 放进 windows/offline/ 再运行"
    RUN_CMD="install.cmd"
    ;;
  macos)
    mkdir -p "$STAGE/mac/keys"
    cp "$ROOT/mac/install-sshd.sh" "$ROOT/mac/install.command" "$ROOT/mac/harden-ssh.sh" "$STAGE/mac/"
    [ -n "$PUB_LINE" ] && printf '%s\n' "$PUB_LINE" > "$STAGE/mac/keys/id_bridge.pub"
    STEPS="1. 解压整个文件夹\n2. 双击 mac/install.command（首次弹窗全部允许）\n3. 把 桌面/部署结果.txt 发回控制端"
    RUN_CMD="双击 mac/install.command"
    ;;
  linux)
    mkdir -p "$STAGE/linux/keys"
    cp "$ROOT/linux/install-sshd.sh" "$STAGE/linux/"
    [ -n "$PUB_LINE" ] && printf '%s\n' "$PUB_LINE" > "$STAGE/linux/keys/id_bridge.pub"
    STEPS="1. 解压后进入 linux/\n2. sudo bash install-sshd.sh --key-file keys/id_bridge.pub\n3. 把 部署结果.txt 发回控制端\n4. 云主机安全组只放行内网/VPN 网段"
    RUN_CMD="sudo bash install-sshd.sh --key-file keys/id_bridge.pub"
    ;;
esac

{
  echo "SSHD Bridge Kit - 离线部署包（$OS_KIND / v$VERSION）"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  echo "【这个包是干什么的】"
  echo "  在这台电脑上开启 SSH 服务，让控制端可以用公钥直接登录。"
  echo ""
  echo "【怎么用】"
  printf '%b\n' "$STEPS"
  echo ""
  echo "【安全说明】"
  echo "  - 只放行内网 10/8、192.168/16、172.16/12 和 Tailscale 100.64/10"
  echo "  - 有公钥时默认关闭密码登录；没有公钥时自动保留密码，避免锁死"
  echo "  - 回滚：Windows 运行 uninstall-sshd.ps1；Unix 用备份的 sshd_config 覆盖后重启"
  echo ""
  echo "启动命令：$RUN_CMD"
} > "$STAGE/部署说明.txt"

# 编码统一：PS1 -> BOM+CRLF，SH -> LF
find "$STAGE" -name '*.ps1' -type f | while read -r f; do
  tmp="$(mktemp)"
  sed 's/\r$//' "$f" | sed 's/$/\r/' > "$tmp"
  printf '\xEF\xBB\xBF' > "$f"
  cat "$tmp" >> "$f"
  rm -f "$tmp"
done
find "$STAGE" \( -name '*.sh' -o -name '*.command' \) -type f -exec sed -i 's/\r$//' {} +

ZIP="$OUT_DIR/$NAME.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -rq "$ZIP" . )
echo ""
echo "=== 部署包已生成 ==="
echo "  目录 : $STAGE"
echo "  压缩 : $ZIP"
if command -v shasum >/dev/null 2>&1; then
  echo "  SHA256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
else
  echo "  SHA256: $(sha256sum "$ZIP" | awk '{print $1}')"
fi
echo ""
echo "把整个文件夹拷到目标机，按 部署说明.txt 操作。"
