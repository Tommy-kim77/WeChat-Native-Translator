# iPhone WeChat Native — password / SMS login feasibility (2026-11-19)

**Status: Offline research only, NOT a working authentication method.**
No account credentials, SMS codes or live login requests used. The installed iPhone app is unchanged.

## Inspected actual sources
- meteor-nb/Ipad860 (commit 4d567bd; cloned under /tmp/wechat-mobile-auth-audit/Ipad860)
  - models/Login/Data62.go: constructs SecManualLoginRequest with username, hashed password, device-security fields, posts via secmanualauth (CGI 252).
  - controllers/Login.go: Data62SMSApply first executes password login, then handles the resulting ticket challenge; SMS verification is a second factor, NOT SMS-only sign-in.
  - Algorithm/CCD.go and clientsdk/v08/v08.go: mobile-security payload requires an opaque DLL / Linux .so; macOS path panics as unsupported; no verified portable iOS-native version.
  - Cilent/mm/mm.pb.go: protobuf schema for ManualAuthRsaReqData, ManualAuthAesReqData, and associated messages.
- liximomo/WeChatAgreement/API.txt: WXUserLogin, WXPhoneLogin, WXGetLoginVerifyCode, WXSendLoginVerifyCode are only external declarations, not the full protocol.
- Current Rust engine:
  - wire.rs::manual_auth encodes request requiring QR-approved opaque c3/c4 credentials; cannot use raw password alone.
  - client.rs::complete_login uses CGI 252 after challenge approval. Endpoint reuse does not prove password login.
  - lib.rs uses desktop identity UnifiedPCLinux x86_64.

## What can and cannot currently be reused
| Part | Present | Gap |
| --- | --- | --- |
| MMTLS transport / CGI 252 | Yes | Verify compatible mobile request and response |
| Protobuf manual auth | QR-specific subset | Mobile password serializer & golden fixtures missing |
| Password proof | Go source includes MD5-to-lower | Missing independently validated safe mobile login flow |
| Anti-abuse device data | Nonportable external dynamic binary | No transparent, verified iOS implementation |
| SMS authentication | Secondary challenge after password in Go sample | Standalone SMS login NOT demonstrated |
| Credential extraction | QR-approved account decoder | Mobile response/session derivation not verified |
| Session identity | Desktop PC | Mobile identity not authenticated |

## Security and testing gates
1. Audit all required mobile security data generation, using native-source iOS-compatible implementation only; do not import opaque Windows/Linux binaries.
2. Implement an isolated offline Rust serializer and decoder with known-good golden test vectors.
3. Verify challenge-state handling, invalid codes, expiry and recovery offline.
4. Enable opt-in real login only once client identity and end-to-end authentication are verified, with secrets entered locally on the iPhone.
5. Keep QR login intact and never treat unverified attempts as successful.

Do not capture WeChat passwords or SMS codes in project files, chat messages, debugging logs, public GitHub, or unverified third-party hosted endpoints. No account authentication was attempted in this audit.

## Reproducibility
Script: ios-probe-app/auth-research/audit_mobile_auth.py
Report: ios-probe-app/auth-research/mobile-auth-audit.json
Reference commit: meteor-nb/Ipad860 4d567bd

## Offline Rust prototype (completed)
- Added mobile_auth_proto_offline.rs to encode the synthetic two-part SecManualLoginRequest envelope and model a strictly local secondary-code challenge.
- rustc 1.93.1 ran 4 offline tests; all 4 passed. No real account password, SMS code, or network request was used.
- The file is intentionally NOT included in the Xcode target and does not claim to implement login.
