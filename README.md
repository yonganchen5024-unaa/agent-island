# Agent Island

macOS 刘海处的“灵动岛”，用来盯住本机的 AI 编程助手：谁在工作、做到哪一步、哪个在等你审批或回答问题。审批可以直接在岛上点“允许”或“拒绝”，结果回传给对应的助手。

A notch "island" for macOS that watches your local AI coding agents (Claude Code, Codex, OpenCode, DSH), shows what each session is doing, and lets you approve or deny their permission requests right from the island.

## 功能

- **会话列表**：Claude Code、Codex 的运行中会话，以及接入后的 OpenCode、DSH 会话，显示会话名、当前步骤、任务清单和子 Agent。点一下跳到对应的终端或 Codex 窗口。
- **审批和提问**：Claude Code、Codex、OpenCode、DSH 发起的权限请求会以卡片出现，展示完整的工具输入。允许、拒绝或回答都会真正回传。小岛出错、超时或没运行时，一律退回助手自己的询问，**不会自动批准**。
- **额度**：Claude 的 5 小时和 7 天额度，Codex 的额度，Kimi Code 的额度（如已登录）。
- **声音和通知**：会话开始、完成、需要审批时的提示音；可选 Bark 推送到 iPhone，默认只在你离开电脑时推送。
- **自动收起**：Claude 会话空闲超过设定时长（默认 2 小时）隐藏，其他助手空闲 10 分钟隐藏，有新动静自动出现。
- **全屏时隐藏、为菜单栏图标让位、悬停展开、快捷键**等。

## 系统要求

- macOS 14 或更高版本，Apple 芯片或 Intel 都可以编译。主要在带刘海的 MacBook 上使用和测试过；没有刘海的屏幕上也显示在顶部中央，但测试较少。
- Xcode 或 Command Line Tools（`xcode-select --install`），用于编译，并提供 `/usr/bin/python3`。
- 想接入的助手本身：[Claude Code](https://docs.anthropic.com/claude-code)、Codex、OpenCode、DSH，装几个接几个。

## 安装

```sh
git clone https://github.com/yonganchen5024-unaa/agent-island.git
cd agent-island
./scripts/install-app.sh            # 编译并安装到 /Applications，设为登录时启动
./scripts/adapters/connect-agents.sh   # 把本机已安装的助手接到小岛
```

`connect-agents.sh` 只改各助手自己的配置，改之前都会在原文件旁边留备份，不改任何权限模式：

| 助手 | 改动 | 生效 |
|---|---|---|
| Claude Code | 在 `~/.claude/settings.json` 追加两组 hook | 新会话 |
| Codex | 在 `~/.codex/hooks.json` 末尾追加审批 hook，并用 Codex 自己的接口信任它 | 新对话 |
| OpenCode | 把插件放进 `~/.config/opencode/plugins/` | 重启 OpenCode |
| DSH | 在 `~/.dsh/profiles/*/cordis.patch.yml` 末尾追加插件，并校验配置 | 重启 DSH |

没装的助手会跳过。

### 什么时候会弹出审批卡片

小岛只在助手**自己要询问你**的时候出现卡片。如果助手设成了全部放行（Claude 的 `bypassPermissions`、Codex 的完全访问、OpenCode 的 `"permission": "allow"`、DSH 的 `danger-full-access`），就不会有审批卡片，小岛只显示状态。Claude 的提问（AskUserQuestion）在任何模式下都会出现。

Codex 在等小岛决定时不会显示它自己的审批框，所以卡片上有“回到 Codex 处理”按钮。

如果你的 Claude Code 由公司策略管理并且只允许受管 hook（`allowManagedHooksOnly`），用户级 hook 不会生效，接入脚本会提示并跳过 Claude。

## 卸载

```sh
./scripts/adapters/connect-agents.sh --undo   # 撤销 Claude、Codex、DSH 的配置改动，并列出 OpenCode 要手动删除的两个文件
./scripts/install-app.sh remove                # 删除应用和登录项
```

## 隐私

- 所有数据都留在本机。小岛读取各助手在本机的会话文件来显示状态，不上传任何内容。
- 额度通过各助手自己的命令行接口查询，小岛不保存、不打印令牌。
- Bark 推送默认只发“需要审批”“全部完工”这类事件文字，不发命令或对话内容；可选加会话名称，可选端到端加密。
- 设置和日志在 `~/Library/Application Support/Agent Island/`。

## 开发

```sh
swift build                                   # 编译
/usr/bin/python3 -I Tests/test_claude_approval_v2.py   # 审批代理和 hook 的协议测试
```

`Tests/` 下的 `*Checks.swift` 是独立的检查程序，文件开头写了要和哪些源文件一起用 `swiftc` 编译。`Tests/e2e/` 是用真实助手程序加本地假模型的端到端测试，需要对应的助手已安装。

## 说明

本项目是独立实现，灵感来自 Vibe Island，与其开发者无关，不包含其代码。如果原版 Vibe Island 正在运行，小岛会把审批让给它，避免两边抢同一个请求。
