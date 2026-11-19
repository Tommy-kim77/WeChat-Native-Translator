# WeChat iPhone Native — 2026-11-19 source snapshot

This separate branch contains the iPhone WeChat application, translated-chat UI, Xcode project, app icon, Rust native transport source, protocol experiments, offline password/SMS feasibility checks, and upstream project support files.

Source material:
- Current iPhone app: `ios-probe-app/` from Mac `Documents/Wechat_Native/ios-agent-wechat-research`.
- Rust protocol engine: `packages/native-client-rust/crates/wechat-protocol/src/lib.rs`, synchronized from the current iPhone development tree.
- Other supporting files: readable local project working copy in `/tmp/agent-wechat-ios-login-retry`.

Security exclusions: private credentials, saved sessions, authorization tokens, provisioning profiles, personal diagnostic logs, and raw QR login images are intentionally not uploaded.

Large generated iPhone app and Rust build outputs are not stored in this source commit. If uploaded successfully, see the Gitea release attachments for the compressed build backup. The source branch may not contain private local runtime data or material that was unreadable in the source directory.

Original Mac and iPhone project files have not been moved or overwritten by this upload process.
