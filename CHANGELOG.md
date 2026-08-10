# Changelog

## v1.2.0 (2026-08-10)

### 中文

- GUI 从 WinForms 重构为 WPF（XAML），全新 **Dawn 浅色**界面（ChatGPT/苹果风格），品牌副标题 `by Dawn`。
- 界面主题：白底 `#F7F7F8`、白色卡片、深色文字，晨曦渐变（暖橙 → 柔蓝）点缀主按钮与进度条；字体 Segoe UI Variable / 微软雅黑。
- 运行中 UI 不冻结：异步子进程 + 日志实时流式回显，新增运行进度条与语义状态徽章（就绪/运行中/完成/未完成）。
- 修复演练模式闪退：异步进程事件竞态处理、全局异常兜底、崩溃日志写入 `%TEMP%\codexmover-crash-*.log`。
- **彻底修复“点开始后窗口消失”**：改为在 GUI 进程内用 PowerShell runspace 直接运行引擎，不再创建隐藏的 powershell 子进程（部分安全软件会拦截/结束这种子进程，导致窗口被悄悄关闭）。引擎输出仍实时流式回显。
- 修复完成回调中计时器变量为空导致的 `$timer.Stop()` 报错（改用事件发送者），并保证任何异常都不会让窗口卡在“运行中”。
- 演练模式自动跳过进程检查：Codex 开着也能直接预览计划，无需关闭应用或使用命令行。
- 新增品牌资产：应用图标（`assets/codex-mover-icon.png`、`assets/app-icon.ico`）与 README banner。
- 新增 `-TestMode`（仅开发/测试用：向引擎传递 `-SkipProcessCheck`）。
- 引擎 `codex-mover.ps1` 保持不变，迁移/备份/校验/回滚逻辑零改动。

### English

- GUI rewritten from WinForms to WPF (XAML) with a new **Dawn light** theme (ChatGPT/Apple style), branded `by Dawn`.
- Streaming logs with async process events; added an indeterminate progress bar and semantic status chip.
- Fixed the dry-run crash: async event race handled, global exception fallback added, crash logs written to `%TEMP%\codexmover-crash-*.log`.
- **Fixed "window disappears after Start"**: the engine now runs in-process via a PowerShell runspace instead of a hidden powershell.exe child process (security software on some machines kills such child processes, silently closing the GUI). Output still streams live.
- Fixed the `$timer.Stop()` null error in the completion callback (use the event sender), and made sure an unexpected error can never leave the window stuck in "running" state.
- Dry-run now skips the process check automatically, so it works while Codex is open.
- Brand assets: app icon (PNG/ICO) and README banner.
- Added `-TestMode` (developer-only: forwards `-SkipProcessCheck` to the engine).
- Engine `codex-mover.ps1` unchanged; migration/backup/verify/rollback logic untouched.

---

## v1.1.0 (2026-08-07)

- 加入 `Documents\Codex` 工作区到默认迁移源；GUI 显示第 5 个来源。
- 引擎新增来源清单（文档同步）。
