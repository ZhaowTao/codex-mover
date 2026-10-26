---
name: Bug report / 问题反馈
about: 迁移失败、报错，或者迁移后 Codex 起不来
title: '[Bug] '
labels: bug
assignees: ''
---

<!--
提交前请先确认：你的场景不在 README 的「已知不适用场景」里
（exFAT 移动硬盘、外接盘、组策略禁符号链接、Codex 没退干净这几类占了大多数）。
-->

## 发生了什么

<!-- 一句话说清，例如：点开始迁移后卡在复制 .codex 这一步，进度条不动 -->

## 期望的结果

<!-- 你本来以为会怎样 -->

## 环境

- Windows 版本（`winver`）：
- PowerShell 版本（`$PSVersionTable.PSVersion`）：
- Codex 版本：
- 目标盘盘符与文件系统（`Get-Volume -DriveLetter G | Format-List FileSystem`）：
- 是否以管理员身份运行：
- 要迁移的源数据大概多大：

## 卡在哪一步

<!-- GUI 右上角状态徽章显示什么，加日志最后 20 行 -->

```
把日志粘在这里
```

日志在目标盘根目录，文件名 `migration-<时间戳>.log`。**贴之前把 `C:\Users\你的名字` 这类用户名和本地路径替换掉。**

## 截图

<!-- 有红字的那一屏，直接拖进来 -->

## 已经试过

- [ ] 完全退出 Codex（含托盘图标）后重试
- [ ] 用「演练模式」或 `-DryRun` 跑过，确认是同一处失败
- [ ] 换过一个空的目标目录
- [ ] 看过 README 的「已知不适用场景」和「遇到问题」两节
