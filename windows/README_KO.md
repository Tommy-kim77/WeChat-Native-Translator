# WeChat Native Translator Windows v0.1.36

Windows 10/11 x64 및 .NET Framework 4.8용입니다. 실행 파일에는 통신 엔진이 포함되어 있습니다.

[실행 파일 다운로드](https://github.com/Tommy-kim77/WeChat-Native-Translator/releases/download/windows-v0.1.36/WeChat-Native-Translator-Windows-v0.1.36-x64.exe)

1. EXE를 실행한 뒤 **QR 로그인**을 누르고 휴대폰 WeChat으로 승인을 완료하세요.
2. **언어 설정**에서 본인의 DeepL API 키를 등록하세요. 번역할 내용은 DeepL 서버로 전송됩니다.
3. 첫 Enter로 번역 미리보기를 만들고, 번역문을 수정한 뒤 Enter로 전송합니다. Shift+Enter는 줄바꿈입니다.

v0.1.36에서는 QR 승인 후 계정 확인이 실패했을 때 로그인 버튼이 계속 잠기는 문제와, 이전 대화를 읽다가 새 메시지·번역·아바타 갱신으로 하단으로 이동하는 문제를 수정했습니다. 맨 아래로 직접 이동하면 최신 메시지를 다시 따라갑니다. v0.1.35의 이전 메시지 불러오기, 초안 보존, 전송 재시도 처리는 유지했습니다.

Windows 10에서 가상 메시지로 UI 검증 10개와 독립 프로필의 내장 엔진 시작 검증을 통과했습니다. 이번 검증은 실제 계정의 송수신·모바일 메시지 동기화를 포함하지 않습니다.

일반 빌드는 `build.ps1 -EnginePath <검증된 엔진 경로>`입니다. 회귀 검증은 `Tests/run-windows.ps1`을 사용합니다. PowerShell 스크립트를 허용하지 않는 환경에서는 보안 설정을 변경하지 않고 `Tests/run-windows.cmd`로 같은 컴파일러를 호출할 수 있습니다. 공유 폴더가 실행을 허용하지 않으면 CMD를 로컬 임시 폴더에 복사한 뒤 첫 번째 인수로 Windows 소스 폴더를 전달하세요. 테스트는 v0.1.35 EXE에 포함된 엔진을 추출하고 빌드에 지정된 SHA-256을 확인합니다.
