using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace NativeTranslator {
 static class UiLanguage {
  public static readonly string[] Choices = { "auto", "ko", "en", "zh-Hans" };
  public static string Preference { get; private set; }
  static string effective;
  static string PreferencePath { get { return Path.Combine(Engine.Data, "interface-language.txt"); } }

  static UiLanguage() {
   var value = "auto";
   try { if (File.Exists(PreferencePath)) value = File.ReadAllText(PreferencePath).Trim(); }
   catch (IOException) {}
   catch (UnauthorizedAccessException) {}
   Apply(value, CultureInfo.CurrentUICulture);
  }

  internal static string Resolve(string preference, CultureInfo system) {
   if (preference != "auto" && Array.IndexOf(Choices, preference) > 0) return preference;
   switch (system.TwoLetterISOLanguageName) {
    case "ko": return "ko";
    case "zh": return "zh-Hans";
    default: return "en";
   }
  }

  static void Apply(string preference, CultureInfo system) {
   Preference = Array.IndexOf(Choices, preference) >= 0 ? preference : "auto";
   effective = Resolve(Preference, system);
  }

  public static void Save(string preference) {
   Directory.CreateDirectory(Engine.Data);
   File.WriteAllText(PreferencePath, preference);
   Apply(preference, CultureInfo.CurrentUICulture);
  }

  public static string Text(string korean) {
   string[] value;
   if (effective == "ko" || !translations.TryGetValue(korean, out value)) return korean;
   return value[effective == "zh-Hans" ? 1 : 0];
  }

  static readonly Dictionary<string,string[]> translations = new Dictionary<string,string[]>(StringComparer.Ordinal) {
   { "이전 메시지", new[] { "Older messages", "更早的消息" } },
   { "메시지 동기화에 실패했습니다. 잠시 후 자동으로 다시 시도합니다.", new[] { "Message sync failed. Retrying automatically shortly.", "消息同步失败，稍后将自动重试。" } },
   { "연결이 끊겼습니다. QR 로그인으로 다시 연결하세요. 작성한 메시지는 유지됩니다.", new[] { "Disconnected. Sign in with QR again. Your draft is retained.", "连接已断开，请重新扫码登录。已保留正在编辑的消息。" } },
   { "이름 검색 · Enter로 전체 메시지 검색", new[] { "Search names · Press Enter to search all messages", "搜索名称 · 按回车搜索全部消息" } },
   { "전체 대화 검색", new[] { "Search all chats", "搜索全部聊天" } },
   { "검색 결과가 없습니다.", new[] { "No results found.", "没有搜索结果。" } },
   { "[지원하지 않는 메시지 유형]", new[] { "[Unsupported message type]", "[不支持的消息类型]" } },
   { "개", new[] { "", "个" } },
   { "검색", new[] { "Search", "搜索" } },
   { "검색할 대화방을 선택하세요.", new[] { "Select a chat to search.", "请选择要搜索的聊天。" } },
   { "계정 응답을 확인할 수 없습니다.", new[] { "Could not verify the account response.", "无法验证账号响应。" } },
   { "그룹 멤버 ", new[] { "Group members: ", "群成员 " } },
   { "그룹 멤버 목록", new[] { "Group member list", "群成员列表" } },
   { "그룹 멤버", new[] { "Group members", "群成员" } },
   { "그룹 이름 조회 실패: ", new[] { "Could not look up group name: ", "无法查询群名称：" } },
   { "그룹 이름", new[] { "Group names", "群名称" } },
   { "그룹·연락처 목록: ", new[] { "Groups and contacts: ", "群组和联系人：" } },
   { "그룹", new[] { "Groups", "群聊" } },
   { "나", new[] { "Me", "我" } },
   { "나중에", new[] { "Later", "稍后" } },
   { "내장 엔진 무결성 검사 실패", new[] { "The bundled engine failed its integrity check.", "内置引擎完整性检查失败。" } },
   { "닫기", new[] { "Close", "关闭" } },
   { "대상 불일치", new[] { "Destination mismatch", "目标不匹配" } },
   { "대상 확인 실패", new[] { "Could not verify the destination.", "无法确认目标" } },
   { "대화 검색", new[] { "Search chats", "搜索聊天" } },
   { "대화 기록 검색", new[] { "Search chat history", "搜索聊天记录" } },
   { "대화 목록 페이지 응답이 반복됩니다.", new[] { "The chat list returned a repeated page.", "聊天列表返回了重复页面。" } },
   { "대화 정보", new[] { "Chat info", "聊天信息" } },
   { "대화", new[] { "Chats", "聊天" } },
   { "대화방 검색", new[] { "Search chats", "搜索聊天" } },
   { "대화방을 선택하세요.", new[] { "Select a chat.", "请选择聊天。" } },
   { "대화방을 선택하세요", new[] { "Select a chat", "请选择聊天" } },
   { "동기화 실패 · ", new[] { "Sync failed · ", "同步失败 · " } },
   { "동영상", new[] { "Video", "视频" } },
   { "등록", new[] { "Register", "注册" } },
   { "로그인 요청 ID를 받지 못했습니다.", new[] { "No sign-in request ID was returned.", "未收到登录请求编号。" } },
   { "로그인한 뒤 대화방을 선택하세요.", new[] { "Sign in and select a chat.", "请登录后选择聊天。" } },
   { "로컬 연결 토큰을 읽지 못했습니다.", new[] { "Could not read the local API token.", "无法读取本地连接令牌。" } },
   { "로컬 토큰 파일 경로가 올바르지 않습니다.", new[] { "The local token file path is invalid.", "本地令牌文件路径无效。" } },
   { "로컬 프로필 경로가 올바르지 않습니다.", new[] { "The local profile path is invalid.", "本地配置路径无效。" } },
   { "로컬 WeChat 연결 엔진을 시작하지 못했습니다.", new[] { "Could not start the local WeChat engine.", "无法启动本地微信引擎。" } },
   { "메시지 회수", new[] { "Recall message", "撤回消息" } },
   { "멘션 뒤에 보낼 내용을 입력하세요.", new[] { "Enter a message after the mention.", "请在提及后输入消息正文。" } },
   { "멘션은 메시지 입력창에서 수정하세요.", new[] { "Edit mentions in the message composer.", "请在消息输入框中编辑提及。" } },
   { "멘션할 그룹 멤버를 불러오지 못했습니다.", new[] { "Could not load group members for mentions.", "无法加载可提及的群成员。" } },
   { "명", new[] { "", "人" } },
   { "목록에서 삭제한 방 모두 복원", new[] { "Restore all chats removed from the list", "恢复从列表移除的全部聊天" } },
   { "목록을 불러오는 중입니다. 잠시 뒤 다시 눌러주세요.", new[] { "The directory is loading. Try again shortly.", "正在加载列表，请稍后再试。" } },
   { "文ᴬ   자동번역 ", new[] { "文ᴬ   Auto-translate ", "文ᴬ   自动翻译 " } },
   { "文ᴬ  번역 미리보기", new[] { "文ᴬ  Translation preview", "文ᴬ  翻译预览" } },
   { "받는 메시지 번역", new[] { "Incoming translation", "接收消息翻译" } },
   { "번역 미리보기", new[] { "Translation preview", "翻译预览" } },
   { "번역 중…", new[] { "Translating…", "正在翻译…" } },
   { "번역기 목록에서 삭제", new[] { "Remove from translator list", "从翻译器列表移除" } },
   { "번역기 목록에서 삭제했습니다. 대화 기록은 보관됩니다.", new[] { "Removed from the translator list. Chat history is retained.", "已从翻译器列表移除，聊天记录仍保留。" } },
   { "번역문을 컴퓨터에 저장하지 못했습니다.", new[] { "Could not save the translation on this computer.", "无法将译文保存到此电脑。" } },
   { "번역문을 확인한 뒤 Enter를 누르세요.", new[] { "Review the translation, then press Enter.", "确认译文后按回车。" } },
   { "번역을 사용하려면 DeepL API 키를 등록하세요.", new[] { "Register a DeepL API key to use translation.", "请注册 DeepL API 密钥以使用翻译。" } },
   { "번역할 메시지 본문을 DeepL에 보냅니다.", new[] { "Message text to translate is sent to DeepL.", "待翻译的消息正文会发送至 DeepL。" } },
   { "보내는 메시지 번역", new[] { "Outgoing translation", "发送消息翻译" } },
   { "보낼 파일 선택", new[] { "Choose a file to send", "选择要发送的文件" } },
   { "브라우저에서 열 수 없습니다.", new[] { "Could not open the browser.", "无法打开浏览器。" } },
   { "비어 있지 않은 512 MiB 이하 파일을 선택하세요.", new[] { "Select a nonempty file no larger than 512 MiB.", "请选择不超过 512 MiB 的非空文件。" } },
   { "사진", new[] { "Photo", "照片" } },
   { "삭제한 방 목록을 읽을 수 없습니다.", new[] { "Could not read the removed chats list.", "无法读取已移除聊天列表。" } },
   { "삭제한 방 목록을 저장할 수 없습니다.", new[] { "Could not save the removed chats list.", "无法保存已移除聊天列表。" } },
   { "새 DeepL API 키", new[] { "New DeepL API key", "新 DeepL API 密钥" } },
   { "선택", new[] { "Select", "选择" } },
   { "선택한 메시지를 위챗에서 회수할까요?", new[] { "Recall this message in WeChat?", "要在微信中撤回这条消息吗？" } },
   { "설정", new[] { "Settings", "设置" } },
   { "스티커", new[] { "Sticker", "表情" } },
   { "승인 완료 · 계정과 대화 목록 확인 중…", new[] { "Approved · Checking the account and chats…", "已批准 · 正在验证账号及聊天列表…" } },
   { "언어 설정", new[] { "Language settings", "语言设置" } },
   { "언어 설정에서 DeepL API 키를 저장하세요.", new[] { "Save a DeepL API key in language settings.", "请在语言设置中保存 DeepL API 密钥。" } },
   { "엔진 경로가 올바르지 않습니다.", new[] { "The engine path is invalid.", "引擎路径无效。" } },
   { "연결됨", new[] { "Connected", "已连接" } },
   { "연락처 이름", new[] { "Contact names", "联系人名称" } },
   { "연락처", new[] { "Contacts", "联系人" } },
   { "열어 본 대화의 수신 메시지 자동 번역", new[] { "Auto-translate incoming messages in open chats", "自动翻译已打开聊天的收到消息" } },
   { "영어 (미국)", new[] { "English (US)", "英语（美国）" } },
   { "오늘", new[] { "Today", "今天" } },
   { "원문 복사", new[] { "Copy original", "复制原文" } },
   { "위챗 이름 조회 실패: ", new[] { "WeChat name lookup failed: ", "微信名称查询失败：" } },
   { "위챗 정보 갱신을 확인하지 못했습니다.", new[] { "Could not confirm the WeChat update.", "无法确认微信信息更新。" } },
   { "위챗에서 연락처 이름을 확인하지 못했습니다.", new[] { "Could not verify the contact name in WeChat.", "无法在微信中确认联系人名称。" } },
   { "위챗에서 전송을 수락하지 않았습니다.", new[] { "WeChat did not accept the send request.", "微信未接受发送请求。" } },
   { "위챗에서 파일 전송을 수락했습니다.", new[] { "WeChat accepted the file.", "微信已接受文件发送请求。" } },
   { "위챗이 회수 요청을 수락했습니다.", new[] { "WeChat accepted the recall request.", "微信已接受撤回请求。" } },
   { "음성", new[] { "Voice", "语音" } },
   { "이 앱에서 숨기기", new[] { "Hide in this app", "在此应用中隐藏" } },
   { "이 파일을 보내시겠습니까?", new[] { "Send this file?", "要发送此文件吗？" } },
   { "이름 미확인 그룹", new[] { "Unnamed group", "未命名群聊" } },
   { "이름 확인 중", new[] { "Checking name", "正在确认名称" } },
   { "이미 실행 중입니다.", new[] { "The app is already running.", "程序已在运行。" } },
   { "인용 답장 작성 중", new[] { "Writing a quoted reply", "正在撰写引用回复" } },
   { "인용 답장", new[] { "Quote reply", "引用回复" } },
   { "인용 메시지 상태를 확인할 수 없습니다.", new[] { "Could not verify the quoted message.", "无法确认引用消息状态。" } },
   { "인용 취소", new[] { "Remove quote", "取消引用" } },
   { "자동 감지", new[] { "Automatic (system)", "自动检测（系统）" } },
   { "자동 번역: ", new[] { "Auto-translation: ", "自动翻译：" } },
   { "자동 번역", new[] { "Auto-translate", "自动翻译" } },
   { "자동 번역에 DeepL API 키가 필요합니다 · 언어 설정", new[] { "Auto-translation requires a DeepL API key · Language settings", "自动翻译需要 DeepL API 密钥 · 语言设置" } },
   { "자동번역", new[] { "Auto-translation", "自动翻译" } },
   { "저장", new[] { "Save", "保存" } },
   { "저장된 그룹 멤버가 없습니다.", new[] { "No group members are saved.", "没有已保存的群成员。" } },
   { "저장된 세션에 다시 연결 중…", new[] { "Reconnecting to the saved session…", "正在重新连接已保存的会话…" } },
   { "전송 결과를 확인하지 못했습니다. 대화 내용을 먼저 확인하세요.", new[] { "Could not confirm delivery. Check the chat before trying again.", "无法确认发送结果，请先查看聊天。" } },
   { "전송 미확인", new[] { "Delivery unconfirmed", "发送未确认" } },
   { "전송 상태 확인 중…", new[] { "Checking delivery status…", "正在确认发送状态…" } },
   { "전송 요청 확인", new[] { "Send request confirmed", "已确认发送请求" } },
   { "전송", new[] { "Send", "发送" } },
   { "전송할 번역문을 입력하세요.", new[] { "Enter a translation to send.", "请输入要发送的译文。" } },
   { "전체", new[] { "All", "全部" } },
   { "정보 갱신 작업 ID가 없습니다.", new[] { "No update operation ID was returned.", "未收到信息更新任务编号。" } },
   { "중국어 (간체)", new[] { "Chinese (Simplified)", "简体中文" } },
   { "채팅", new[] { "Chats", "聊天" } },
   { "첨부 상태: ", new[] { "Attachment status: ", "附件状态：" } },
   { "첨부 선택 · 최신순", new[] { "Select an attachment · Newest first", "选择附件 · 最新优先" } },
   { "첨부 작업의 대상을 확인하지 못했습니다.", new[] { "Could not verify the attachment job destination.", "无法确认附件任务目标。" } },
   { "첨부 저장", new[] { "Save attachment", "保存附件" } },
   { "첨부파일 대상 불일치", new[] { "Attachment destination mismatch", "附件目标不匹配" } },
   { "첨부파일 크기 불일치", new[] { "Attachment size mismatch", "附件大小不匹配" } },
   { "첨부파일을 가져올 수 없습니다.", new[] { "Could not retrieve the attachment.", "无法获取附件。" } },
   { "첨부파일을 저장했습니다.", new[] { "Attachment saved.", "附件已保存。" } },
   { "첨부파일이 512 MiB를 초과합니다.", new[] { "The attachment exceeds 512 MiB.", "附件超过 512 MiB。" } },
   { "최근 대화", new[] { "Recent chats", "最近聊天" } },
   { "최근 숨김 취소", new[] { "Undo last hide", "撤销上次隐藏" } },
   { "키를 저장할 수 없습니다. 다시 시도하세요.", new[] { "Could not save the key. Try again.", "无法保存密钥，请重试。" } },
   { "파일 보내기", new[] { "Send file", "发送文件" } },
   { "파일 전송 결과를 확인하지 못했습니다. 대화 내용을 먼저 확인하세요.", new[] { "Could not confirm the file send. Check the chat before trying again.", "无法确认文件发送结果，请先查看聊天。" } },
   { "파일 전송 대상을 확인하지 못했습니다.", new[] { "Could not verify the file destination.", "无法确认文件发送目标。" } },
   { "파일 전송 상태: ", new[] { "File send status: ", "文件发送状态：" } },
   { "파일 전송 중…", new[] { "Sending file…", "正在发送文件…" } },
   { "파일 전송", new[] { "File Transfer", "文件传输助手" } },
   { "파일", new[] { "File", "文件" } },
   { "프로필 권한 검사 실패", new[] { "Profile permission check failed", "配置权限检查失败" } },
   { "프로필 데이터베이스 오류", new[] { "Profile database error", "配置数据库错误" } },
   { "프로필 잠금 오류", new[] { "Profile lock error", "配置锁定错误" } },
   { "한국어 ", new[] { "Korean ", "韩语 " } },
   { "한국어", new[] { "Korean", "韩语" } },
   { "한국어로 메시지 입력...", new[] { "Enter a message in Korean…", "输入韩语消息…" } },
   { "한국어로 메시지 입력", new[] { "Enter a message in Korean", "输入韩语消息" } },
   { "현재 대화에 저장할 첨부가 없습니다.", new[] { "This chat has no attachments to save.", "当前聊天没有可保存的附件。" } },
   { "화면 언어", new[] { "Interface language", "界面语言" } },
   { "회수 상태: ", new[] { "Recall status: ", "撤回状态：" } },
   { "회수된 메시지", new[] { "Recalled message", "已撤回的消息" } },
   { "휴대폰 승인 완료 · 계정 또는 대화 목록 확인 실패: ", new[] { "Phone approval complete · Could not verify the account or chats: ", "手机已批准 · 无法验证账号或聊天列表：" } },
   { "휴대폰 승인 완료 · 계정 또는 대화 목록 확인 실패", new[] { "Phone approval complete · Could not verify the account or chats", "手机已批准 · 无法验证账号或聊天列表" } },
   { "휴대폰 승인 완료 · 엔진에서 계정 인증 상태를 확인하지 못했습니다.", new[] { "Phone approval complete · The engine could not confirm authentication.", "手机已批准 · 引擎无法确认认证状态。" } },
   { "휴대폰 WeChat에서 QR 로그인을 승인하세요.", new[] { "Approve QR sign-in in WeChat on your phone.", "请在手机微信中批准扫码登录。" } },
   { "휴대폰 WeChat으로 QR을 스캔하세요.", new[] { "Scan the QR code with WeChat on your phone.", "请使用手机微信扫描二维码。" } },
   { "DeepL 번역 결과가 비어 있습니다.", new[] { "DeepL returned an empty translation.", "DeepL 返回了空译文。" } },
   { "DeepL 요청 실패 (", new[] { "DeepL request failed (", "DeepL 请求失败 (" } },
   { "DeepL 키 (빈칸이면 기존 키 유지)", new[] { "DeepL key (leave blank to keep the current key)", "DeepL 密钥（留空保留现有密钥）" } },
   { "DeepL API 키 등록", new[] { "Register DeepL API key", "注册 DeepL API 密钥" } },
   { "DeepL API 키", new[] { "DeepL API key", "DeepL API 密钥" } },
   { "DeepL API 홈페이지 열기", new[] { "Open the DeepL API website", "打开 DeepL API 官网" } },
   { "Enter 번역 → Enter 전송 · Shift+Enter 줄바꿈", new[] { "Enter to translate, Enter to send · Shift+Enter for a new line", "回车翻译，再按回车发送 · Shift+Enter 换行" } },
   { "QR 로그인 ", new[] { "QR sign-in: ", "扫码登录：" } },
   { "QR 로그인 시간이 만료됐습니다.", new[] { "The QR sign-in code expired.", "二维码已过期。" } },
   { "QR 로그인", new[] { "Sign in with QR code", "扫码登录" } },
   { "QR 이미지 응답이 올바르지 않습니다.", new[] { "The QR image response is invalid.", "二维码响应无效。" } },
   { "WeChat 대화 목록 동기화", new[] { "Sync WeChat chats", "同步微信聊天列表" } },
   { "WeChat 동기화 완료 · 최근 대화 ", new[] { "WeChat sync complete · Recent chats: ", "微信同步完成 · 最近聊天 " } },
   { "WeChat 연결 요청 실패 (", new[] { "WeChat connection request failed (", "微信连接请求失败 (" } },
   { "WeChat QR 로그인", new[] { "WeChat QR sign-in", "微信扫码登录" } },
   { "WeChat에 로그인한 뒤 동기화하세요.", new[] { "Sign in to WeChat before syncing.", "请先登录微信再同步。" } },
   { "WeChat에서 최근 대화와 방 이름 동기화 중…", new[] { "Syncing recent chats and names from WeChat…", "正在同步微信最近聊天及名称…" } },
  };
 }
}
