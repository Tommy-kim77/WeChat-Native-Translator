# iOS native WeChat authentication feasibility check — 2026-11-19

## Inspected source
- Rust engine: `packages/native-client-rust/crates/wechat-protocol/src/client.rs`
- Current prelogin paths: `getloginqrcode`, `checkloginqrcode`, `secmanualauth` (after QR approval) and `secautoauth` (existing accepted session).
- No implemented first-time password, mobile-phone, SMS/voice, email, QQ, Facebook, or passkey login entry point was found in inspected Rust protocol source.
- `AccountState.database_password` refers to the local profile database key, NOT an account sign-in password.
- WeChat's third-party OAuth SDK is not a drop-in replacement for native WeChat account authentication.

## Implemented behavior
- QR login remains the current first-time supported login.
- Accepted credential state is stored in iOS Keychain via the Xcode auto-signed app; successful simulator logout/relaunch-free session restoration was observed.
- Other login methods appear in a clearly marked protocol-pending informational UI; no passwords, SMS codes, or personal identifiers are collected or sent.
- Current engine device profile `UnifiedPCLinux x86_64` represents a desktop profile; simulator results do not prove a real iPhone native protocol.

## Validation gates before enabling other login methods
1. Obtain independently verified iOS mobile protocol evidence for each method: request/response formats, cryptography, device identity, and challenges.
2. Validate failed and success response cases on a dedicated test account, without collecting private secrets in logs.
3. Ensure iOS Keychain storage, explicit consent, rate limiting, retries and account security/challenge pathways.
4. Compile/test the actual iPhone arm64 target (not just the simulator); test alongside the official app.
5. Only then enable the method and show a real submission control.

This audit is a code-based scope statement, not a claim that the mobile login protocol was implemented or verified.
