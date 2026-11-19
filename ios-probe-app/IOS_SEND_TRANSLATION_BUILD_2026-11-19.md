# iPhone text send and Apple Translation prototype — 2026-11-19

- Device: iPhone 15 Pro Max (iOS 27.2.1).
- Keychain SESSION_RESTORED, PUSH_CONNECTED, SYNC_SUCCESS: 6 chats, 31 messages.
- Observed on-device send status ACCEPTED: server acceptance only, not proof of delivery.
- No auto send or automatic resend. User must confirm recipient and message.
- Apple Translation is wired to display Korean translations beneath incoming originals, but actual display and language model download are not yet tested on the phone.
- Research app stores chat JSON in temporary plaintext (not production history storage).
- iOS app background direct TCP push is not reliable during suspension/killed state; reliable real-time notifications require separately approved APNs provider/server or another supported iOS background mechanism, not yet implemented.
- First-time phone/SMS/password and actual iOS native authentication profiles remain unimplemented.

Build sources:
- ios-probe-app/main.m
- ios-probe-app/TranslationBridge.swift
- ios-probe-app/WeChatProbe.xcodeproj
- packages/native-client-rust/crates/wechat-protocol/src/lib.rs
- packages/native-client-rust/target/aarch64-apple-ios/debug/libwechat_protocol.a

Note: Rust source hydration in original Mac Files/Documents tree may be incomplete due to FileProvider placeholders; the static library was built from an accessible isolated source copy and saved to canonical target path.

## Conversation name, avatar and UI matching extension (2026-11-19)
- Added per-conversation server contact record requests via existing authenticated NativeClient `lookup_contacts` RPC.
- Added avatar bytes requests via existing `download_avatars` RPC; accepted only JPEG/PNG signatures, limited size, stored in app temporary directory using hashed filenames.
- Writes `wechat-ios-directory.json` separately and atomically so UI can preserve raw peer IDs for sending while displaying verified remark/nickname and photos.
- On physical iPhone, metadata produced **six display names and four valid profile images**, including **both currently synchronized group conversations**. Counts checked by `devicectl` from app container.
- List refresh reacts to directory data changes. Group filter uses raw `@chatroom` ID (not display name).
- Native list UI updated to white cells with 48pt thumbnail images, chat names, preview text and timestamps; chat page uses gray background and green/white bubble colors inspired by the user-provided screenshots of official WeChat.
- Caution: group-message sender avatars and complete historical conversation discovery are still unsupported; image display and live text translation require on-screen user validation. Chat message bodies remain temporary research data.

## Editable translation and direct user-initiated send
- Changed translated draft preview to an editable UITextView. Source and translation remain separate; users can revise the translated text.
- On Send button, choose edited translated text when translation is active; otherwise send original.
- Removed selection and pre-send confirmation pop-ups; no automatic sending occurs, only the explicit Send tap.
- Report outcome through navigation prompt without modal alerts. No automatic retry and preserve drafts for rejected or uncertain results.
- iPhone arm64 compile/build, device install, launch, Keychain restoration, Push connected verified. Translation and delivery still require direct UI verification.

## Accepted outgoing persistence, dual-direction translation, local chat removal
- Actual server-accepted sends are saved to app-local Application Support accepted-outgoing.json, with file protection. App merges accepted sends with server sync data and displays them immediately as outgoing chat bubbles, retaining after app restarts.
- Duplicate merge checks server-synced outgoing body and timestamp within 180 seconds; this is a provisional heuristic until server ID reconciliation is implemented.
- Incoming and outgoing message text both enter Apple Translation (to selected received-language target); no network translations are attempted without supported Apple framework resources.
- Conversation list swipe-left action removes the room from the *app's list only*. A confirmation explicitly states official WeChat history is untouched. Hidden peers persist and can be restored with top navigation '복원' control.
- iPhone arm64 build, developer signing, install, launch, restored Keychain authentication and Push connectivity succeeded. Actual outgoing send and translation-display interactions require a user-run end-to-end check.
- Existing older outgoing messages that WeChat did not include in this client’s received sync cannot yet be reconstructed from official history. Server-side deletion was deliberately not implemented.

## Fix based on screenshot: mixed Chinese/English translation and oversized composer
- Translation bridge now detects source language for each input message with NaturalLanguage. Chinese short-text Han script fallback uses explicit `zh-Hans`; English uses `en`.
- Apple Translation sessions are created per message rather than mixing languages inside one session. A completion yields to the main actor before starting the next translation request.
- Failed translations are displayed inline as `번역 실패 · 언어팩/지원 언어 확인`, rather than silently disappearing.
- Raw `[Non-text message]` placeholder shows `첨부·미디어 메시지 (미리보기 미지원)`, which is explicitly not actual attachment/media rendering.
- Two editable message input fields each reduced to 48pt height, action bar to 34pt.
- Signed iOS arm64 build, physical-device install/launch, Keychain restoration, and Push connection succeeded. Actual Korean result for short Chinese must be confirmed on physical iPhone; language pack downloads may require on-device approval.

## Auto detect English/Chinese -> Korean (November 19)
- Received-message UI now explicitly labels '영어·중국어 자동감지 → 한국어' instead of asking for manual source-language selection.
- NaturalLanguage source detection is performed per message; Han script detection now takes precedence over statistical recognition to handle short Chinese such as `你好` and `今天是几号？`. Latin-letter fallback detects short English.
- Outgoing/incoming synced messages both use same target-Korean translation engine. Original text remains visible above translations.
- The manual *draft* target-language selector is retained because this serves outgoing translation to English/Chinese.
- Built/signed/installed/launched on actual iPhone; verified Keychain restoration and Push connection. Actual display for every short Chinese message remains for on-screen confirmation.

## Latest-message automatic scroll fix
- ChatDetailController viewDidAppear scrolls to actual content bottom after layout.
- On new sync, auto-scroll happens when viewer was already near latest message; reading old messages is preserved instead of jumping to bottom.
- Translation bridge instrumentation and queue sequencing fixes are included; the translation diagnostics log is stored in the app temporary folder, with only status and counts, no message text.
- Physical iPhone build, signing, install, launch and Keychain restoration and Push connection verified. Visual scroll and translation completion need on-device confirmation.

## Follow scrolling after dynamically inserted translations
- Initial room open schedules bottom-scrolling after first layout.
- Uses tableView scrollToRowAtIndexPath(last) plus corrected content inset offset.
- Translation completion records whether the user is near bottom before reloading self-sizing rows, then follows the newest message after the layout pass only in that case.
- Reading older history should not be interrupted by automatic scrolling.
- iPhone arm64 build/sign/install and session restore/Push connection verified. On-device visual behavior requires verification.

## Korean translation result persistence
- Successful English/Chinese -> Korean translations now persist inside the app's Application Support as `translated-ko-v1.json`, file protection CompleteUntilFirstUserAuthentication.
- When reopening chat rooms or restarting the app, cached translated texts are loaded immediately and Apple Translation requests are skipped for cached originals.
- Errors/failure placeholders are not saved as translations. Identical source strings share a cached Korean translation. Up to 10,000 entries / 8 MiB pilot cap; consider SQLite for production.
- Built and installed on physical iPhone; direct UI translation and persistence-after-relaunch need user validation.

## Group roster, local-message removal, sanitized media send failure diagnostics
- Native chat-group toolbar '멤버' invokes authenticated `lookup_room(room,0)` via Rust FFI on a background worker and shows member names. Selecting a member inserts @display-name into the editable draft. The protocol-level @ notification metadata is not yet sent/verified; this is display/draft selection only.
- Tapping a message opens '메시지 관리' -> '이 앱에서 삭제', persistently hidden locally using message key hashes. This does NOT recall or delete messages for the recipient in official WeChat.
- Recall exists in the Mac protocol using CGI594 but requires verified local message ID, source time and accepted server ID; iPhone currently lacks complete source IDs, so safe server recall is not enabled.
- Real iPhone prior media attempt showed `MEDIA_UNCERTAIN_NO_RETRY` without a stage. Added per-stage sanitized diagnostic status for file read/CDN bootstrap/upload/server submit; exact failure pending next explicit user-initiated send. Never automatically retries uncertain outbound media.
- Physical iPhone build and install/launch verified; dynamic member roster and message deletion need UI check.

## Exact recently-sent text recall and detailed file send diagnostics
- For new text messages only, Rust saves a bounded local journal after verifying server acceptance, including server ID, local send ID, timestamp, peer and sending account identity, and no text body.
- UIKit joins the verified latest receipt by peer and SHA256 of sent text, and presents '전송 취소 (서버 회수)' only for accepted messages within 120 seconds. Requires user confirmation.
- Rust cross-checks the journal, authenticated own account, exact IDs and <=120-second age. Marks attempt before RPC so uncertain results are never automatically reissued. Successful server response hides locally accepted and matching server message ID in the app. Actual server recall acceptance/delivery to recipient requires physical testing.
- File uploads now report a sanitized step of failure: read, CDN bootstrap, prepare, CDN upload, server message submit. The prior attempt's status was only MEDIA_UNCERTAIN_NO_RETRY, which did not identify the failing stage. Do not claim the file send path is repaired before observing fresh status from user-initiated upload.
- Group '멤버' offers room roster and selection, but actual protocol-level @mention notification is still pending verification.

## Group information screen matching official WeChat screenshot
- Replaced group-member action sheet with a separate navigation screen resembling official '채팅 정보(11)' UI.
- Six-column grid shows validated member usernames/display names and thumbnail photos retrieved on demand from authenticated room roster and avatar APIs; photo fallback used if not provided.
- Tapping member adds @display-name to chat draft. Protocol-level real @-mention remains unverified and should not be claimed as working.
- Read-only rows: group name, QR-code placeholder, group notices, description, search, user nickname, chat background; show explicit unsupported notice if tapped.
- Local-only preferences: mute, pin, address book, show members' nicknames. These DO NOT change official WeChat server settings, and some preferences are not wired to functional behavior yet.
- Built, signed, and installed on actual iPhone. UI-specific navigation and profile photo rendering require on-device verification.

## November 19 14:25: Group avatar batch correction and ellipsis button
- User reported member images absent. Physical-device roster artifact confirmed 11 members and **zero** avatar references, despite successful roster lookup.
- Root cause: avatar_request in wechat-protocol permits at most 2 usernames per RPC, whereas initial room code attempted a single batch of up to 20, ignored error and showed placeholders.
- Fixed batch size to 2, and added fallback to contact metadata's advertised avatar URL, downloaded only from validated public avatar domains.
- Group chat's top-right navigation button changed from the word '멤버' to '···'.
- New status logs number of successfully resolved member images. iPhone arm64 Rust + Xcode builds and installation succeeded; actual per-member imagery requires opening the group information view in-app to trigger fetch.

## Use the exact Mac WeChat Native Translator icon on iPhone
- Verified that the Mac-installed `/Applications/WeChat Native Translator v0.2.10.app/Contents/Resources/AppIcon.icns` SHA256 matches the project `Resources/AppIcon.icns` exactly.
- Rendered original 1024x1024 Mac icon to a non-alpha 1024x1024 PNG on white background, added a real `Assets.xcassets/AppIcon.appiconset/Contents.json` iOS catalog.
- Wired asset catalog into Xcode resource phase and `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for both Debug and Release; checked built Info.plist `CFBundleIconName = AppIcon` and compiled `Assets.car`.
- Built, signed and installed updated app on connected physical iPhone, with app account data preserved.

## Suppressed synthetic unsupported-media placeholder chat bubbles
- User confirmed generic '첨부·미디어 메시지 (미리보기 미지원)' continued appearing as visible outgoing chat bubbles.
- Fixed root UI behavior: message model filters the exact synthetic `[Non-text message]` and its Korean replacement upon chat opening AND live updates, instead of changing a placeholder's wording.
- No WeChat message or downloaded media is deleted; non-text messages remain in synced snapshot pending actual image/file rendering support. This is UI-only visibility suppression.
- Signed iOS arm64 build and physical iPhone installation/launch verified.

## Persistent discovered chatrooms vs full historical room inventory
- Found a critical prior bug: each push sync wrote only rooms in current incremental conversation map, overwriting `wechat-ios-chats.json` and losing rooms absent from new sync. Added merge of prior and newly synced rooms with server-message-ID dedup and bounded per-room message retention.
- iPhone verified 8 existing discovered rooms (including 3 groups) and 93 message rows before patch; installation and Keychain restore and Push connection succeeded. Additional sync should preserve these plus future rooms.
- Server `init_contacts` catalog returned 246 contacts and 0 chatrooms; this is not a complete ordered conversation/room list. Separate group inventory endpoint requires an opaque cursor; a complete initial cursor and full historical chat list are not yet confirmed. Do not present the 246 contacts as 246 historical conversations.
- Full restore of all pre-existing WeChat conversation history not implemented; requires verified server conversation-history enumeration or supported user export, not fabricated data.

## Distinguish actual discovered chats from unsynchronized contacts in unified list
- Reported iOS UI showed only 8 rooms, whereas official app has many more pre-existing chats.
- Added '전체 보기' default tab showing 8 confirmed discovered chat rooms followed by remaining server-listed contact entries, visibly marked '연락처 · 과거 대화 기록 미수집' rather than mislabeled historical chat rooms. Separate tabs: 최근 대화, 그룹, 연락처.
- A contact entry opens an empty draft-capable chat only; does NOT restore historical messages or imply that a past chat definitely existed.
- Mac app's data `session.db` is encrypted/unreadable as ordinary SQLite, and Mac's `wx` backend has `/threads` API, but has not yet provided an account-scoped export of full history.
- Built and installed on real iPhone; check actual user-visible room/contact distinction next.

## November 19 15:00 screenshot feedback
- User screenshot shows 8 true synced rooms and 237 unhistoried contact entries; no claim all existing WeChat conversations restored.
- Main list previously showed internal '[Non-text message]' for almost every room. Preview now picks latest actual text in each room; uses generic '미디어 메시지' when only media placeholders are available.
- Chat screen screenshot shows last translated message cut off above input composer. Added second layout cycle on chat open and on translations, with bottom content inset. Visual behavior still requires user confirmation.
- iPhone arm64 build succeeded, installed and launched on attached iPhone.

## iPhone stopped receiving while Mac receives: automatic sync reconnect
- Observed iPhone LIVE_SYNC_ERROR Broken pipe (os error 32) followed by FAILED, leaving a still-running app process with a dead sync worker. Mac app process and local account remained online.
- Wrapped live sync loop with explicit retry on sync socket failure, bounded to 12 attempts with 2–30s backoff, and pushed reconnect errors similarly. Preserve the existing sync cursor and accumulated message history on reconnect; no duplicate outbound sends are performed.
- Rust iPhone arm64 and signed Xcode build succeeded. Installed and started on real attached iPhone, account restore and push connection verified. Concurrent long-running reception with active Mac desktop client still needs end-to-end testing.
- Both iPhone and Mac currently present PC identity to WeChat server; simultaneous independent desktop sessions are not guaranteed by protocol.

## Password/SMS authentication research (not enabled)
- Reviewed real Go source from meteor-nb/Ipad860 (commit 4d567bd) and documented mobile manual-auth field mapping, SMS second-factor semantics, and external v08 binary blocker.
- Saved structured read-only audit + repeatable Rust offline frame and challenge fixture under ios-probe-app/auth-research.
- All four Rust offline tests passed. No credential use, WeChat auth calls, changes to user sessions, or iPhone deployment performed for this research. Password/SMS login is not yet implemented.
