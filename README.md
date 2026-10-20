# Plain Craft Launcher (PCL) 第三方版本维护脚本

PCL 原作者：[龙腾猫跃](https://github.com/LTCatt) · [支持原作者](https://meloong.com/afd/a/LTCat) · [上游项目](https://github.com/Meloong-Git/PCL)

本项目由第三方独立维护，提供 PCL 版本检查、更新配置修改和历史版本安全替换脚本。与 PCL 官方无隶属或授权背书关系。

保留上游原始 [LICENCE](LICENCE)，来源、命名及许可说明见 [NOTICE.md](NOTICE.md)。仓库仅包含脚本、测试与说明；历史发行包按需从上游固定提交下载并校验，不随本仓库分发。


适用于 Windows，自带的 Windows PowerShell 5.1 即可运行，不需要安装 Python，也不需要管理员权限。

## 普通用户操作

1. 只下载 [Protect-PCL.cmd](Protect-PCL.cmd) 一个文件，保存到任意可写文件夹。GitHub 文件页中点击 **Download raw file**，避免保存成网页。
2. 关闭 PCL。双击 `Protect-PCL.cmd`，在窗口中选择平时启动游戏使用的 PCL EXE。
3. 脚本自动识别版本并处理，完成后显示备份位置和恢复命令。

| 检测结果 | 自动操作 |
| --- | --- |
| 2.x 且低于 2.99.0.0 | 保留 EXE，只将更新设置改为关闭 |
| 2.99.0.0 | 下载固定的官方 2.14.0.0，校验、备份，再替换 EXE 并关闭更新 |
| 其他版本、无法识别、PCL 仍在运行 | 停止操作并显示原因 |

不会自动启动 PCL。完成后请自己启动，核对版本、更新设置和下载页面。

`Protect-PCL.cmd` 已内嵌完整 PowerShell 脚本，独立运行时无需另下 PS1。启动时仅将内嵌源码写入新建的临时文件，运行后清理。仓库中的 `Protect-PCL.ps1` 是便于维护和审阅的源码。

## 保存和替换规则

- 仅处理选定的 EXE 和同目录的 `PCL\Setup.ini`。保留 EXE 的原文件名，不修改游戏、存档、模组或其他配置。
- 修改配置时保留其余内容、换行格式和 UTF-8 / 带 BOM 的 UTF-16 编码；无 BOM 且非 UTF-8 时尝试系统 ANSI 编码。遇到无法识别的编码则停止。重复的 `SystemSystemUpdate` 项都会改为 `3`。
- 修改前，把原文件逐字节备份到 EXE 同目录下的 `PCL-Backups\时间-唯一编号`，并记录原路径和 SHA-256。原先不存在的文件会在清单中注明。
- 下载包和解压出的 EXE 都必须匹配脚本内固定的 SHA-256；只提取指定 EXE，不执行下载内容。断网、下载失败、校验失败均不会替换原 EXE 或配置。
- 在同一磁盘暂存，通过 `File.Replace` 替换已有文件；替换期间阻止其他程序写入原文件，同一启动器的脚本操作互斥。备份失败、文件被占用或文件在操作期间变化时停止。多文件修改中途失败，会尝试恢复已修改文件；如果恢复受阻，原始备份仍保留。
- 恢复备份前也会备份当前内容。原先不存在的配置文件在手动恢复时保留，不会为恢复“不存在”而删除当前内容。恢复旧配置可能重新开启更新。
- 拒绝网络共享、符号链接和目录联接。不自动结束进程、不修改注册表、不修改系统执行策略；CMD 中的执行策略参数仅适用于本次 PowerShell 进程。

回退来源为[官方仓库固定历史提交中的压缩包](https://github.com/Meloong-Git/PCL/blob/5ef81e490ae46b1100d61e33d0183094c7a80ca8/%E6%9C%80%E6%96%B0%E6%AD%A3%E5%BC%8F%E7%89%88.zip)。脚本校验值由上游仓库同一提交中的原文件计算，并非从下载地址动态获取。

公开源码提供了 `SystemSystemUpdate:3`（关闭更新提示）设置，但官方发行版的完整更新实现未公开。本脚本不会修改其内部更新逻辑，也不保证此设置能够阻止官方可能实施的强制更新。已在运行的更新进程需要先退出。

## 命令行用法

以下命令在 Windows PowerShell 中执行；将路径替换成实际位置。

```powershell
# 指定 EXE；也可指定只有一个 PCL EXE 的文件夹
.\Protect-PCL.ps1 -Path 'D:\Games\PCL\我的启动器.exe'

# 只查看版本和处理方案，不写文件、不下载
.\Protect-PCL.ps1 -Path 'D:\Games\PCL' -WhatIf

# 网络不可用时，使用提前下载好的官方历史压缩包（同样校验哈希）
.\Protect-PCL.ps1 -Path 'D:\Games\PCL' -RollbackArchive 'D:\Downloads\PCL-2.14.zip'

# 恢复某次备份；当前文件会另行备份
.\Protect-PCL.ps1 -RestoreBackup 'D:\Games\PCL\PCL-Backups\实际备份目录名'
```

如果 PS1 被执行策略拦截，使用 CMD 入口即可；组织策略明确禁止运行脚本时，应遵循该策略。

CMD 入口同样支持上述参数，例如 `& '.\Protect-PCL.cmd' -WhatIf` 或 `& '.\Protect-PCL.cmd' -RestoreBackup '实际备份目录'`。

## 维护单文件入口

修改 `Protect-PCL.ps1` 后，在 Windows PowerShell 中运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Standalone.ps1` 重新生成 CMD；不应单独编辑 CMD 内的载荷。测试会检查内嵌内容与源码是否一致。

## 验证

`tests\Protect-PCL.Tests.ps1` 默认从上游固定提交下载新旧发行包并校验 SHA-256，在隔离目录验证版本识别、配置保留、回退、恢复、校验失败和运行中拒绝等行为。测试只需 Windows PowerShell 5.1，不依赖原启动器源码、Git 历史或额外测试框架；下载失败时停止测试。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Protect-PCL.Tests.ps1

# 加上 -Online，同时验证主脚本的完整联网回退流程（只操作测试目录）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Protect-PCL.Tests.ps1 -Online
```

离线运行时，可使用 `-FixtureDirectory 'D:\TestFixtures'` 指定自行准备的测试目录，其中应包含原版 `old.exe`（2.14.0.0）、`new.exe`（2.99.0.0）及对应的 `old.zip`、`new.zip`。测试样本与运行生成的备份均由 `.gitignore` 排除，不应提交到 GitHub。
