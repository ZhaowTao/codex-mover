# Changelog

## v1.2.0 (2026-08-10)

### 中文

- GUI 从 WinForms 重构为 WPF（XAML），全新 **Dawn 极简深色**界面（ChatGPT/苹果风格），品牌副标题 `by Dawn`。
- 界面主题：深灰 `#121212` 底、柔和晨曦渐变（暖橙 → 柔蓝）、大圆角卡片；字体 Segoe UI Variable / 微软雅黑。
- 运行中 UI 不冻结：异步子进程 + 日志实时流式回显，新增运行进度条与语义状态徽章（就绪/运行中/完成/未完成）。
- 新增品牌资产：应用图标（`assets/codex-mover-icon.png`、`assets/app-icon.ico`）与 README banner。
- 新增 `-TestMode`（仅开发/测试用：向引擎传递 `-SkipProcessCheck`）。
- 引擎 `codex-mover.ps1` 保持不变，迁移/备份/校验/回滚逻辑零改动。

### English

- GUI rewritten from WinForms to WPF (XAML) with a new **Dawn minimal dark** theme, branded `by Dawn`.
- Streaming logs with async process events; added an indeterminate progress bar and semantic status chip.
- Brand assets: app icon (PNG/ICO) and README banner.
- Added `-TestMode` (developer-only: forwards `-SkipProcessCheck` to the engine).
- Engine `codex-mover.ps1` unchanged; migration/backup/verify/rollback logic untouched.

---

## v1.1.0 (2026-08-07)

- 加入 `Documents\Codex` 工作区到默认迁移源；GUI 显示第 5 个来源。
- 引擎新增来源清单（文档同步）。
