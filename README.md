# TaskTick

<p align="center">
  <img src="docs/icon.svg" width="128" height="128" alt="TaskTick Icon">
</p>

<p align="center">
  <strong>A native macOS app for managing scheduled tasks.</strong><br>
  <em>macOS 原生定时任务管理，开箱即用，菜单栏常驻。</em>
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases">Download</a> ·
  <a href="https://lifedever.github.io/TaskTick/">Website</a> ·
  <a href="https://lifedever.github.io/sponsor/">Sponsor</a>
</p>

<p align="center">
  <a href="#features">English</a> | <a href="#功能特色">中文</a>
</p>

---

## Features

- **Menu Bar Resident** — runs in background, always accessible from menu bar
- **Flexible Scheduling** — cron expressions (with visual editor & presets) or fixed intervals
- **Script Execution** — inline scripts or local files (.sh, .py, .rb, .js)
- **Execution Logs** — stdout/stderr capture, exit codes, duration tracking
- **Notifications** — macOS system notifications on success/failure
- **i18n** — English & Simplified Chinese, switchable in-app
- **Auto Updates** — checks GitHub Releases for new versions
- **macOS 26 Ready** — liquid glass effects on supported systems

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon or Intel Mac

## Install

### Download

Grab the latest `.dmg` from [Releases](https://github.com/lifedever/TaskTick/releases):

| File | Architecture |
|------|-------------|
| `TaskTick-x.x.x-arm64.dmg` | Apple Silicon (M1/M2/M3/M4) |
| `TaskTick-x.x.x-x86_64.dmg` | Intel Mac |

> **Note:** The app is not notarized by Apple. On first launch:
>
> **Right-click TaskTick.app → Open → Open**
>
> Or run: `xattr -cr /Applications/TaskTick.app`

### Build from Source

```bash
git clone https://github.com/lifedever/TaskTick.git
cd TaskTick
swift build -c release
swift run
```

## Tech Stack

- **SwiftUI** — declarative UI framework
- **SwiftData** — persistence (SQLite under the hood)
- **Swift Package Manager** — build system & dependency management

## License

MIT © [lifedever](https://github.com/lifedever)

---

## 功能特色

- **菜单栏常驻** — 后台静默运行，菜单栏随时访问
- **灵活调度** — Cron 表达式（可视化编辑器 & 预设）或固定间隔
- **脚本执行** — 内联脚本或本地文件（.sh、.py、.rb、.js）
- **执行日志** — 捕获 stdout/stderr、退出码、执行耗时
- **系统通知** — 任务成功或失败时推送 macOS 原生通知
- **中英双语** — 支持中英文界面，App 内一键切换
- **自动更新** — 检查 GitHub Releases 获取新版本
- **支持 macOS 26** — 液态玻璃视觉特效，旧系统优雅降级

## 系统要求

- macOS 15 (Sequoia) 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

### 下载

从 [Releases](https://github.com/lifedever/TaskTick/releases) 下载最新 `.dmg`：

| 文件 | 架构 |
|------|------|
| `TaskTick-x.x.x-arm64.dmg` | Apple Silicon (M1/M2/M3/M4) |
| `TaskTick-x.x.x-x86_64.dmg` | Intel Mac |

> **注意：** 本应用未经 Apple 公证。首次打开时：
>
> **右键点击 TaskTick.app → 打开 → 打开**
>
> 或在终端执行：`xattr -cr /Applications/TaskTick.app`

### 从源码构建

```bash
git clone https://github.com/lifedever/TaskTick.git
cd TaskTick
swift build -c release
swift run
```

## 技术栈

- **SwiftUI** — 声明式 UI 框架
- **SwiftData** — 数据持久化（底层 SQLite）
- **Swift Package Manager** — 构建系统与依赖管理

## 开源协议

MIT © [lifedever](https://github.com/lifedever)
