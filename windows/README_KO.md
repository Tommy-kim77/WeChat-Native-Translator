# WeChat Native Translator Windows v0.1.1

`Releases/v0.1.1/WeChat-Native-Translator-Windows-v0.1.1-x64.exe`는 Windows 10/11 x64와 .NET Framework 4.8을 대상으로 합니다. 단일 EXE에 Agent WeChat 2.3.0을 포함하며 실행 시 현재 사용자 전용 폴더에 엔진을 풉니다.

**QR 로그인**을 클릭한 뒤 휴대폰 WeChat으로 QR을 스캔하고 승인하세요. 번역은 **언어 설정**에 저장한 DeepL API 키를 사용합니다. 첫 Enter는 번역 미리보기, 다음 Enter는 전송입니다. 번역문을 편집할 수 있고 Shift+Enter는 줄바꿈입니다. 앱과 엔진 데이터는 `%LOCALAPPDATA%\WeChat Native Translator Windows`에 저장됩니다.

Mac v0.2.3 기준으로 목록 필터, 언어 선택, 기록 검색, 그룹 멤버 보기, 연락처 이름 조회와 원문 복사·인용·숨기기·회수 메뉴를 이식했습니다. 기존 프로필에서 모바일 승인 후 엔진 HTTP 500이 관측됐으며, 실제 계정에서 위 기능을 검증하지 못했습니다. Apple Translation, 아바타, 그룹 초대, 멘션 작성, UI 언어 전환은 미이식입니다.

재빌드는 [Agent WeChat 2.3.0 Windows x64 엔진](https://github.com/thisnick/agent-wechat/releases/tag/v2.3.0)을 받아 `./build.ps1 -EnginePath <엔진 경로>`로 실행합니다. 빌드가 엔진 SHA-256을 검증하고 엔진과 라이선스를 EXE에 포함합니다.
