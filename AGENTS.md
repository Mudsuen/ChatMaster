# ChatMaster project rules

- Native macOS SwiftPM app (`com.mudsuen.ChatMaster`). SwiftUI + AppKit; no web wrapper.
- Database access is read-only. Never write to the WeChat container, never modify `WeChat.app`
  or `WeChat-dbg.app`, never inject code into WeChat. Direct replies from the MenuBar popover
  are strictly user-triggered and operate only via standard Accessibility / CGEvent UI actions.
- Keys come only from user-supplied local config (`~/.wechat-decrypt/all_keys.json` or `$WXDEC_HOME`). Do not copy keys,
  decrypted data, or chat content into this repository, tests, logs, or docs.
- LLM calls go through `agy` print mode with a JSON schema, `--sandbox`, and the empty
  `agy-workspace`. Only user-triggered analyses or explicitly watched chats may send content.
- Do not nest `HSplitView` or `.searchable(placement: .sidebar)` inside the
  `NavigationSplitView` detail: it causes an AppKit constraint-loop crash.
- Verify: `swift build && swift test`; headless data path `.build/release/chatmasterctl status`.
  Package: `./script/package_app.sh`; install: `./script/build_and_run.sh --install`.
  Keep the Apple Development signing identity so TCC permissions persist.
