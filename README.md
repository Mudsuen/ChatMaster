# ChatMaster

> **使用声明 / Scope Notice**：**ChatMaster 仅用于本地只读分析用户已解密（或已由用户自行配置本地访问密钥）的个人聊天数据。** 本项目不包含任何解密、密钥提取、内存读取或绕过加密的功能。

Native macOS (SwiftUI + AppKit) companion & analyzer for the owner's own decrypted local WeChat 4.x chat history.

- **Data**: reads already-decrypted / user-configured local SQLCipher databases **read-only** using a user-supplied key configuration (`~/.wechat-decrypt/all_keys.json` or `$WXDEC_HOME/all_keys.json`). SQLCipher, OpenSSL `libcrypto` and
  zstd are linked statically from Homebrew. New messages (including those still in the WAL) are
  indexed every 2 seconds.
- **Index**: `~/Library/Application Support/ChatMaster/lens.sqlite` (dir 700, files 600;
  automatically migrated from legacy `WeChatLens` on upgrade):
  normalized messages, FTS5 trigram search, local sentiment estimate, analysis cache, watchlist.
- **LLM**: `agy -p --output-format json --json-schema …` in an empty working directory with
  `--sandbox`; chat text is passed as delimited data and the prompt forbids tool use.
- **UI Dependency**: references sibling local Swift package `../MudsUI`.

## Features

| Area | What it does |
|---|---|
| 概览 | totals, period switcher (`今日` / `7 天` / `30 天` / `全部`), 90-day volume, interactive weekday × hour heatmap, top chats |
| 会话 | chat list + transcript with muted & recalled filters; inline recalled originals; hover/right-click a bubble to analyze; AI conversation summary |
| 待回复 | chats where the other side is waiting (questions, requests, @mentions, wait time) |
| 关系洞察 | per-contact stats (share, initiations, reply latency, sentiment trend, hours) + AI report |
| 顶部搜索 | floating top-bar search panel (`⌘K`) with full-text search + chat scope, time range, recalled-only, private/group, and sender filters |
| 每日简报 | AI digest: highlights, needs-reply, my promises, mood alerts |
| 防撤回 | WeChat rewrites a recalled row in place into a `revokemsg` system message; the index keeps the original text, records `recalled_at`, displays/filters it directly inside `会话` and top-bar search, and posts a notification. Works only while ChatMaster runs (2 s sync); media keeps its type only |
| MenuBar 快捷消息 | shows recent non-muted, non-folded private & group chats with unread badge; inline mini-transcript, AI reply suggestions, and user-triggered direct reply via Accessibility / CGEvent |
| 微信伴侣 | sidebar docked to the WeChat window, copy-to-analyze bubble, ⌃⌥A OCR capture, ⌃⌥V clipboard, ⌃⌥S toggle sidebar |

ChatMaster never injects into or modifies WeChat. WeChat 4.x exposes no chat content via
Accessibility, so it uses the window frame (AX), the clipboard, the index, and optional OCR of
the window title (Screen Recording permission) to follow the open chat. Without OCR it follows
`SessionTable.last_clear_unread_timestamp` (bumped when a chat is opened) and messages I send.

## Design

The UI follows Bencho's design language (bencho.dev) via the shared `MudsUI` package: `tokens.css`
colour ramp, 20 pt paper cards with hairlines instead of shadows, ink-slab pill buttons, one
near-critical spring, and colour only where it carries meaning.

## Build, test, install

```sh
swift build && swift test
./script/package_app.sh            # dist/ChatMaster.app, signed with the Apple Development identity
./script/build_and_run.sh --install
.build/release/chatmasterctl status|sync|menubar|recent|analyze <id>|conv <chat>|rel <chat>|brief
```

Requires macOS 26 (the Homebrew static libraries target it), `brew install sqlcipher zstd`,
and a logged-in `agy` CLI.

## Permissions

- App Data access to `~/Library/Containers/com.tencent.xinWeChat` (prompted once).
- Accessibility: locate the WeChat window for the docked sidebar and MenuBar direct reply.
- Screen Recording (optional): OCR of the WeChat title bar (used to verify active chat before sending) and ⌃⌥A region capture.

## Automation hook

`DistributedNotificationCenter` name `com.mudsuen.ChatMaster.navigate`, object one of
`section:<dashboard|chats|pending|insight|briefing>`, `chat:<username>`,
`search:<open|close|query>`, `inspect:<message id>`, `insight:<username>`, `popup:<text>`, `companion:<username|follow>`.
Used for local UI verification.
