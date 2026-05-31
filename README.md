<p align="center">
  <img src="https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows" alt="Windows">
  <img src="https://img.shields.io/badge/shell-PowerShell-5391FE?style=flat-square&logo=powershell" alt="PowerShell">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen?style=flat-square" alt="Zero Dependencies">
</p>

<h1 align="center">codex-session</h1>
<p align="center"><strong>Zero-friction multi-account session switcher for Codex CLI</strong></p>

<p align="center">
  <img src="https://raw.githubusercontent.com/hicancan/codex-session/main/.github/demo.svg" alt="demo" width="600">
</p>

---

## 这是什么 / What

Codex 只支持单账号登录。多个 ChatGPT 账号（不同 Plan、不同额度）来回切换，需要手动删除 `auth.json`、手动复制备份。

`codex-session` 把这个流程变成一行命令。每次运行自动保存当前 token，切换账号瞬间完成。

Codex supports only a single login. Switching between ChatGPT accounts means manually deleting and copying `auth.json` files. `codex-session` reduces this to a single command — auto-saves your current session, switches instantly.

## 安装 / Install

```powershell
git clone https://github.com/hicancan/codex-session.git <your-path>
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;<your-path>", "User")
```

将 `<your-path>` 替换为你想存放的位置（如 `D:\tools\codex-session`），重启终端后 `codex-session` 全局可用。

## 使用 / Usage

```powershell
# 显示已保存账号，选择切换
codex-session

# 全量字段对比表
codex-session list

# 直接切换到指定账号（支持模糊匹配）
codex-session switch hihui

# 保存当前 session 并删除 auth.json，准备登录新号
codex-session logout
```

## 原理 / How It Works

```
Codex 登录 → ~\.codex\auth.json 生成
     ↓
codex-session  →  自动保存到 sessions\<email>\auth.json
     ↓
codex-session switch xxx  →  覆盖 ~\.codex\auth.json，完成切换
```

- **自动保存** — 每次运行都持久化当前 session，token 永不过期
- **自动覆盖** — 同邮箱 session 自动覆盖，始终最新
- **自动清理** — logout 自动保存 + 删除，为登录新号准备

- **Auto-save** — persists current session on every invocation
- **Auto-overwrite** — same-email sessions overwritten, always fresh
- **Auto-cleanup** — logout saves + deletes, ready for new login

## 安全 / Security

| 问题 | 答案 |
|---|---|
| token 会推到 GitHub 吗？ | 不会。`sessions/` 目录已在 `.gitignore` 中 |
| 其他人能看到我的 token 吗？ | 不能。所有 session 数据仅在本地 |
| token 刷新了怎么办？ | 每次运行自动保存，始终跟着官方刷新 |

> **No.** `sessions/` is gitignored. Only the script itself is tracked. All tokens stay local.

## 文件结构 / Structure

```
codex-session/
├── .gitignore              # 忽略 sessions/（token 安全）
├── codex-session.cmd        # CMD 入口 → pwsh
├── codex-session.ps1        # 主脚本，纯 PowerShell，零依赖
└── sessions/                # 账号数据（gitignored）
    ├── alice@gmail.com/auth.json
    ├── bob@outlook.com/auth.json
    └── ...
```

## License

MIT
