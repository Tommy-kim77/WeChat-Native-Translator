# WeChat iOS native independent sign-in feasibility / build report — 2026-11-19

## Confirmed
- Current Rust transport offers desktop-profile QR login, post-approval manual auth, and accepted-session auto-auth renewal.
- A real iPhone `aarch64-apple-ios` Rust static library **built successfully**.
- An iPhone-arm64 (not Simulator) WeChatProbe.app **built and linked successfully** with `CODE_SIGNING_ALLOWED=NO`.
- Binary: `ios-probe-app/iphone-arm64-build/WeChatProbe.app/WeChatProbe`. This is UNSIGNED; it is not installable on a physical iPhone until properly signed.
- Existing iPhone Simulator QR/Keychain session restoration / Push sync previously tested successfully.

## Not implemented or verified
- First-time WeChat account login by WeChat ID + password, phone + password, phone + SMS, email + password, voice verification, QQ, Facebook or Apple passkey.
- A **verified** mobile native account-authentication protocol is not in the inspected Rust code. The official Open Platform OAuth mobile SDK authorizes a third-party app but does not supply WeChat native chat transport credentials.
- No real iPhone was detected in `xcrun devicectl list devices` (an Apple Watch and Simulator were listed); physical-device installation or login cannot yet be claimed.
- The current binary uses `UnifiedPCLinux x86_64` device profile, and real mobile-protocol identity/account coexistence remain unverified.

## Required to implement real first-time login
1. Acquire authorized, independently validated mobile account-auth protocol evidence for challenge initiation, password/SMS proof, device identity, error/challenge handling, and server-accepted credential state.
2. Build an isolated native protocol implementation and offline fixtures/test harness without transmitting unverified requests or recording user secrets.
3. Integrate iOS Keychain and password-only-in-memory handling; enable input and request submission only after the backend passes authentication tests.
4. Sign the app using a proper provisioning profile and test an actual iPhone account login with user approval.

The app's current 'other sign-in methods' UI is explicitly labeled verification pending. No alternative login credential is collected.
