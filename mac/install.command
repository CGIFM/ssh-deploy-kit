#!/bin/bash
# 双击入口：自动提权并执行 install-sshd.sh
cd "$(dirname "$0")" || exit 1
chmod +x ./*.sh 2>/dev/null
bash ./install-sshd.sh "$@"
status=$?
echo
if [ -t 0 ]; then
  read -n 1 -s -r -p "按任意键关闭..."
  echo
fi
exit $status
