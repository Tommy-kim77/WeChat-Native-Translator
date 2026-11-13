# WeChat Native Translator

An independent macOS client for WeChat with built-in translation. It connects through Agent WeChat and signs in with a QR code approved in the WeChat mobile app.

## Features

- Automatically translate Korean, English and Simplified Chinese messages, including quoted replies, into the selected incoming language.
- Use the macOS preferred language for the app interface and the initial incoming translation. Open Language settings to choose the interface language, incoming translation and outgoing translation separately. The app remembers each selection.
- Apple Translation is the default and needs no API key. To use DeepL, choose it in Language settings and verify your own [DeepL API key](https://developers.deepl.com/docs/getting-started/auth). The app stores the key in macOS Keychain. DeepL receives the text it translates, and those requests count toward your DeepL API usage.
- Press Enter to preview an outgoing translation. Edit the translation if needed, then press Enter or click Send. Use Shift+Enter for a new line.
- Browse chats with their original names, contact photos and group avatars. Recently loaded conversations appear while the app refreshes their history.
- In group chats, incoming messages show the sender's WeChat display name and profile photo when available. Search any conversation's locally synced message history using the magnifying glass.
- Use the message's `…` menu to copy the original text, quote a message, hide a message in this app, or ask WeChat to recall a message you sent. WeChat determines recall eligibility.
- In a group, type `@` and choose a member to send a WeChat mention. Use the `…` button to view members and invite contacts. In a direct chat, use `…` to refresh the contact name from WeChat or set a display nickname for this app.
- Clear unread counts when opening a conversation, send files, and save available attachments.

## Build on macOS

Version 0.2.3 targets Apple Silicon and macOS 15 or later. Install the Xcode command-line tools and obtain the Apple Silicon `wx` binary from [Agent WeChat v2.3.0](https://github.com/thisnick/agent-wechat/releases/tag/v2.3.0). Follow the upstream [binary verification instructions](https://thisnick.github.io/agent-wechat/setup/install/) and make the downloaded file executable. From this directory run:

```sh
bash build.sh /absolute/path/to/wx-v2.3.0-darwin-arm64
```

The build prints the app bundle path and saves the ZIP under `Releases/` by default. The app filename and window title include the version. Pass a second argument to choose another ZIP path. If the verified engine is already at `Dependencies/wx`, run `bash build.sh` without arguments. The script signs the app ad hoc for local development. Public macOS binary distribution is a separate release step.

Open the built app, scan its QR code with the WeChat mobile app, and approve sign-in. Apple Translation may prompt you to download the languages you use. The app stores its engine profile under `~/Library/Application Support/WeChat Native Translator`. Keep that directory private, as it contains local account and chat data. A fresh profile displays the history synced to that profile.

## Project status

The current source builds the macOS app. Windows is a proposed port. This is a community project unaffiliated with Tencent or WeChat. The connection engine is developed by [Agent WeChat](https://github.com/thisnick/agent-wechat); its license is included in [AGENT-WECHAT-LICENSE](AGENT-WECHAT-LICENSE).

## 한국어 안내

위챗 모바일 앱으로 QR을 스캔하면 맥에서 대화할 수 있습니다. 앱 화면과 받는 메시지의 기본 번역 언어는 맥의 선호 언어를 따릅니다. **언어 설정**에서 앱 화면, 받는 메시지 번역, 보내는 메시지 번역을 각각 선택할 수 있으며 앱을 다시 실행해도 설정이 유지됩니다. 한국어·영어·중국어 간 자동 번역과 인용 답장을 지원합니다. 메시지 입력 후 Enter를 누르면 번역문이 표시됩니다. 번역문을 직접 수정한 뒤 Enter를 누르거나 **전송**을 클릭하면 수정한 내용이 전송됩니다. Shift+Enter는 줄바꿈입니다. 대화방 이름은 원문 그대로 표시하며 파일 송수신을 지원합니다.

현재 버전은 Apple Silicon 맥과 macOS 15 이상용입니다. 빌드에는 Xcode 명령줄 도구와 위에서 안내한 Agent WeChat `wx` 실행 파일이 필요합니다.

그룹에서 받은 메시지 위에 보낸 사람 이름과 프로필 사진을 표시합니다. 돋보기로 이 기기에 동기화된 대화 기록을 검색할 수 있습니다. 말풍선 옆 `…` 메뉴에서 복사, 인용 답장, 이 앱에서 숨기기를 사용할 수 있습니다. 내가 보낸 메시지는 위챗이 허용하는 경우 상대방 화면에서도 회수할 수 있습니다.

Apple 번역이 기본값입니다. DeepL을 사용하려면 **언어 설정 → 번역 엔진**에서 DeepL을 선택하고 본인의 DeepL API 키를 확인·저장하세요. 키는 macOS 키체인에 저장됩니다. DeepL을 선택한 동안 번역하는 텍스트는 DeepL 서버로 전송되며 API 사용량이 차감됩니다.
