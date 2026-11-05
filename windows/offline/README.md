# 离线安装包放这里

Windows 目标机没有外网时，把微软官方签名包放到本目录，文件名必须为：

```
OpenSSH-Win64.msi
```

## 获取方式

在有网的机器上下载（微软官方 GitHub Releases）：

```
https://github.com/PowerShell/Win32-OpenSSH/releases
```

选 `OpenSSH-Win64-*.msi`，重命名为 `OpenSSH-Win64.msi`。

## 完整性校验

建议同时放一个 `OpenSSH-Win64.msi.sha256`，内容为：

```
<64位十六进制哈希>  OpenSSH-Win64.msi
```

生成：

```powershell
(Get-FileHash .\OpenSSH-Win64.msi -Algorithm SHA256).Hash
```

安装脚本检测到 sidecar 文件时会强制比对；没有 sidecar 时只校验微软签名。

## 如果安全软件会杀 PowerShell 安装器

改用预先编译好的单文件离线安装器（EXE 内嵌 OpenSSH），
它不依赖 PowerShell 执行安装逻辑，适合 EDR 严格的目标机。
