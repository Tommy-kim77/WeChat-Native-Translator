using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  const string DeepLApiHomepage = "https://www.deepl.com/en/products/api";

  LinkLabel DeepLHomepageLink() {
   var link = new LinkLabel { Text = UiLanguage.Text("DeepL API 홈페이지 열기"), AutoSize = true };
   link.LinkClicked += (sender, args) => {
    try {
     System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(DeepLApiHomepage) { UseShellExecute = true });
    } catch (System.ComponentModel.Win32Exception) {
     MessageBox.Show(this, DeepLApiHomepage, UiLanguage.Text("브라우저에서 열 수 없습니다."));
    }
   };
   return link;
  }

  bool EnsureDeepLKey() {
   if (!string.IsNullOrWhiteSpace(translator.Key)) return true;
   using (var dialog = new Form { Text = UiLanguage.Text("DeepL API 키 등록"), ClientSize = new System.Drawing.Size(430, 185),
    AutoScaleMode = AutoScaleMode.Dpi, StartPosition = FormStartPosition.CenterParent,
    FormBorderStyle = FormBorderStyle.FixedDialog, ShowInTaskbar = false, MaximizeBox = false, MinimizeBox = false }) {
    var stack = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(14) };
    var key = new TextBox { Width = 380, UseSystemPasswordChar = true, AccessibleName = UiLanguage.Text("DeepL API 키") };
    var save = new Button { Text = UiLanguage.Text("등록"), AutoSize = true, Enabled = false };
    var later = new Button { Text = UiLanguage.Text("나중에"), AutoSize = true, DialogResult = DialogResult.Cancel };
    var buttons = new FlowLayoutPanel { AutoSize = true };
    buttons.Controls.AddRange(new Control[] { save, later });
    var error = new Label { AutoSize = true, ForeColor = System.Drawing.Color.Firebrick };
    stack.Controls.AddRange(new Control[] {
     new Label { Text = UiLanguage.Text("번역을 사용하려면 DeepL API 키를 등록하세요."), AutoSize = true },
     DeepLHomepageLink(), key, buttons, error
    });
    key.TextChanged += (sender, args) => { save.Enabled = !string.IsNullOrWhiteSpace(key.Text); error.Text = ""; };
    save.Click += (sender, args) => {
     var value = key.Text.Trim();
     if (value.Length == 0) return;
     try {
      translator.SetKey(value);
      dialog.DialogResult = DialogResult.OK;
     } catch (IOException) {
      error.Text = UiLanguage.Text("키를 저장할 수 없습니다. 다시 시도하세요.");
     } catch (UnauthorizedAccessException) {
      error.Text = UiLanguage.Text("키를 저장할 수 없습니다. 다시 시도하세요.");
     } catch (System.Security.Cryptography.CryptographicException) {
      error.Text = UiLanguage.Text("키를 저장할 수 없습니다. 다시 시도하세요.");
     }
    };
    dialog.Controls.Add(stack);
    dialog.AcceptButton = save;
    dialog.CancelButton = later;
    dialog.ActiveControl = key;
    return dialog.ShowDialog(this) == DialogResult.OK;
   }
  }

  string SettingsPath { get { return Path.Combine(Engine.Data, "preferences.txt"); } }
  void SavePreferences() {
   Directory.CreateDirectory(Engine.Data);
   File.WriteAllLines(SettingsPath, new[] { incoming.ToString(), outgoing.ToString(), automatic.ToString() });
  }
  void LoadSettings() {
   automatic = true;
   if (!File.Exists(SettingsPath)) return;
   var settings = File.ReadAllLines(SettingsPath);
   int a, b;
   if (settings.Length != 3 || !int.TryParse(settings[0], out a) || !int.TryParse(settings[1], out b)) return;
   if (a < 0 || a >= languages.Length || b < 0 || b >= languages.Length) return;
   incoming = a; outgoing = b; automatic = settings[2] == "True";
  }
  void Settings() {
   if (busy) return;
   using (var dialog = new Form { Text = UiLanguage.Text("언어 설정"), Width = 550, Height = 450, StartPosition = FormStartPosition.CenterParent }) {
    var stack = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(12), AutoScroll = true };
    var display = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200, AccessibleName = UiLanguage.Text("화면 언어") };
    display.Items.AddRange(new object[] { UiLanguage.Text("자동 감지"), "한국어", "English", "简体中文" });
    display.SelectedIndex = Array.IndexOf(UiLanguage.Choices, UiLanguage.Preference);
    var received = LanguagePicker(incoming);
    var sending = LanguagePicker(outgoing);
    var key = new TextBox { Width = 380, UseSystemPasswordChar = true, AccessibleName = UiLanguage.Text("새 DeepL API 키") };
    var auto = new CheckBox { Text = UiLanguage.Text("열어 본 대화의 수신 메시지 자동 번역"), Checked = automatic, AutoSize = true };
    var confirm = new Button { Text = UiLanguage.Text("저장"), DialogResult = DialogResult.OK, AutoSize = true };
    stack.Controls.AddRange(new Control[] { new Label { Text = UiLanguage.Text("화면 언어"), AutoSize = true }, display,
     new Label { Text = UiLanguage.Text("받는 메시지 번역"), AutoSize = true }, received,
     new Label { Text = UiLanguage.Text("보내는 메시지 번역"), AutoSize = true }, sending,
     new Label { Text = UiLanguage.Text("DeepL 키 (빈칸이면 기존 키 유지)"), AutoSize = true }, key, auto,
     DeepLHomepageLink(), new Label { Text = UiLanguage.Text("번역할 메시지 본문을 DeepL에 보냅니다."), AutoSize = true }, confirm });
    dialog.Controls.Add(stack); dialog.AcceptButton = confirm;
    if (dialog.ShowDialog(this) != DialogResult.OK) return;
    try {
     if (key.Text.Trim() != "") translator.SetKey(key.Text.Trim());
     incoming = received.SelectedIndex; outgoing = sending.SelectedIndex; automatic = auto.Checked;
     autoToggle.Checked = automatic;
     SavePreferences();
     var language = UiLanguage.Choices[display.SelectedIndex];
     if (language != UiLanguage.Preference) {
      UiLanguage.Save(language);
      if (room != null) drafts[room] = draft.Text;
      ReloadInterface = true;
      dialog.Close();
      Close();
      return;
     }
     ClearPreview(); Render();
     if (automatic && translator.Key != "" && room != null) TranslateInBackground(room);
    } catch (Exception error) { status.Text = error.Message; }
   }
  }
  static ComboBox LanguagePicker(int selected) {
   var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 170 };
   box.Items.AddRange(new object[] { UiLanguage.Text("한국어"), UiLanguage.Text("영어 (미국)"), UiLanguage.Text("중국어 (간체)") });
   box.SelectedIndex = selected;
   return box;
  }
  async Task<IDictionary<string,object>> WaitJob(IDictionary<string,object> job, string kind) {
   var id = Engine.Get(job, "id");
   for (int i = 0; ; ++i) {
    if (id == "" || Engine.Get(job, "id") != id || Engine.Get(job, "accountId") != account || Engine.Get(job, "kind") != kind)
     throw new IOException(UiLanguage.Text("첨부 작업의 대상을 확인하지 못했습니다."));
    var state = Engine.Get(job, "state");
    if (i == 120 || (state != "queued" && state != "running")) return job;
    await Task.Delay(1000, Cancel);
    job = await engine.Json(AccountPath + "/jobs/" + Engine.Part(id), Cancel);
   }
  }
  async Task SendAttachment() {
   if (!connected || room == null || rooms.SelectedItem == null) throw new IOException(UiLanguage.Text("대화방을 선택하세요."));
   var id = room;
   using (var dialog = new OpenFileDialog { Title = UiLanguage.Text("보낼 파일 선택"), CheckFileExists = true }) {
    if (dialog.ShowDialog(this) != DialogResult.OK) return;
    var file = new FileInfo(dialog.FileName);
    if (file.Length < 1 || file.Length > 512L * 1024 * 1024) throw new IOException(UiLanguage.Text("비어 있지 않은 512 MiB 이하 파일을 선택하세요."));
    if (MessageBox.Show(this, title.Text + "\n" + file.Name, UiLanguage.Text("이 파일을 보내시겠습니까?"), MessageBoxButtons.YesNo) != DialogResult.Yes) return;
    string source;
    using (var input = file.OpenRead())
    using (var parts = new MultipartFormDataContent()) {
     parts.Add(new StreamContent(input), "file", file.Name);
     using (var response = await engine.Request(AccountPath + "/uploads", Cancel, HttpMethod.Post, parts)) {
      await response.Content.LoadIntoBufferAsync(1024 * 1024);
      var data = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string,object>>(await response.Content.ReadAsStringAsync());
      source = Engine.Get(data, "id");
     }
    }
    if (source == "" || id != room) throw new IOException(UiLanguage.Text("파일 전송 대상을 확인하지 못했습니다."));
    status.Text = UiLanguage.Text("파일 전송 중…");
    try {
     var job = await engine.Json(AccountPath + "/sends", Cancel, new { threadId = id, sourceId = source, kind = "file" }, Guid.NewGuid().ToString("N"));
     if (Engine.Get(job, "threadId") != id || Engine.Get(job, "sourceId") != source) throw new IOException(UiLanguage.Text("대상 불일치"));
     job = await WaitJob(job, "send");
     status.Text = Engine.Get(job, "state") == "accepted" ? UiLanguage.Text("위챗에서 파일 전송을 수락했습니다.") : UiLanguage.Text("파일 전송 상태: ") + Engine.Get(job, "state");
    } catch (Exception) { if (!closing) status.Text = UiLanguage.Text("파일 전송 결과를 확인하지 못했습니다. 대화 내용을 먼저 확인하세요."); }
   }
  }
  sealed class Attachment {
   public string Id, Name;
   public override string ToString() { return Name; }
  }
  async Task SaveAttachment() {
   var candidates = shown.Where(x => AttachmentLabel(x) != "").Reverse()
    .Select((x, i) => new Attachment { Id = Engine.Get(x, "id"), Name = (i + 1) + ". " + AttachmentLabel(x) }).ToArray();
   if (candidates.Length == 0) throw new IOException(UiLanguage.Text("현재 대화에 저장할 첨부가 없습니다."));
   Attachment choice;
   using (var picker = new Form { Text = UiLanguage.Text("첨부 선택 · 최신순"), Width = 400, Height = 340, StartPosition = FormStartPosition.CenterParent }) {
    var list = new ListBox { Dock = DockStyle.Fill };
    list.Items.AddRange(candidates); list.SelectedIndex = 0;
    var button = new Button { Text = UiLanguage.Text("선택"), Dock = DockStyle.Bottom, DialogResult = DialogResult.OK };
    picker.Controls.Add(list); picker.Controls.Add(button); picker.AcceptButton = button;
    if (picker.ShowDialog(this) != DialogResult.OK) return;
    choice = (Attachment)list.SelectedItem;
   }
   var path = AccountPath + "/messages/" + Engine.Part(choice.Id);
   var assets = Engine.Items(await engine.Json(path + "/media", Cancel)).Where(x => Engine.Get(x, "accountId") == account && Engine.Get(x, "messageId") == choice.Id);
   var order = new[] { "original", "standard", "normal", "encoded", "thumbnail" };
   var asset = assets.OrderBy(x => { var index = Array.IndexOf(order, Engine.Get(x, "variant")); return index < 0 ? 99 : index; })
    .FirstOrDefault(x => new[] { "available", "pending", "failed" }.Contains(Engine.Get(x, "state")));
   if (asset == null) throw new IOException(UiLanguage.Text("첨부파일을 가져올 수 없습니다."));
   var assetId = Engine.Get(asset, "id");
   var assetPath = AccountPath + "/media/" + Engine.Part(assetId);
   if (Engine.Get(asset, "state") != "available") {
    var jobId = Engine.Get(asset, "jobId");
    var job = jobId == "" ? await engine.Json(path + "/media-transfers", Cancel, new { messageId = choice.Id, assetId = assetId, quality = Engine.Get(asset, "variant") })
     : await engine.Json(AccountPath + "/jobs/" + Engine.Part(jobId), Cancel);
    if (Engine.Get(job, "assetId") != assetId) throw new IOException(UiLanguage.Text("첨부파일 대상 불일치"));
    job = await WaitJob(job, "download");
    if (Engine.Get(job, "state") != "available") throw new IOException(UiLanguage.Text("첨부 상태: ") + Engine.Get(job, "state"));
    asset = await engine.Json(assetPath, Cancel);
   }
   if (Engine.Get(asset, "id") != assetId || Engine.Get(asset, "accountId") != account || Engine.Get(asset, "messageId") != choice.Id || Engine.Get(asset, "state") != "available")
    throw new IOException(UiLanguage.Text("첨부파일 대상 불일치"));
   var name = new string(Engine.Get(asset, "filename").Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c).ToArray()).TrimEnd('.', ' ');
   using (var dialog = new SaveFileDialog { FileName = name == "" ? "attachment" : name, OverwritePrompt = true }) {
    if (dialog.ShowDialog(this) != DialogResult.OK) return;
    var temp = dialog.FileName + "." + Guid.NewGuid().ToString("N") + ".partial";
    try {
     using (var res = await engine.Request(assetPath + "/content", Cancel))
     using (var input = await res.Content.ReadAsStreamAsync())
     using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true)) {
      var buffer = new byte[65536];
      int size;
      while ((size = await input.ReadAsync(buffer, 0, buffer.Length, Cancel)) != 0) {
       if (output.Length + size > 512L * 1024 * 1024) throw new IOException(UiLanguage.Text("첨부파일이 512 MiB를 초과합니다."));
       await output.WriteAsync(buffer, 0, size, Cancel);
      }
      long expected;
      if (output.Length == 0 || (long.TryParse(Engine.Get(asset, "byteLength"), out expected) && expected != output.Length)) throw new IOException(UiLanguage.Text("첨부파일 크기 불일치"));
     }
     if (File.Exists(dialog.FileName)) File.Replace(temp, dialog.FileName, null);
     else File.Move(temp, dialog.FileName);
     status.Text = UiLanguage.Text("첨부파일을 저장했습니다.");
    } finally { if (File.Exists(temp)) File.Delete(temp); }
   }
  }
 }
 static class Program {
  [STAThread] static int Main(string[] args) {
   System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
   if (args.Length == 2 && args[0] == "--verify-package") return Smoke.Run(args[1]);
   if (args.Length == 2 && args[0] == "--verify-qr") return Smoke.Run(args[1], true);
   if (args.Length == 2 && args[0] == "--design-preview") return CaptureDesign(args[1]);
   bool first;
   using (var mutex = new Mutex(true, "Local\\WeChatNativeTranslatorWindows", out first)) {
    if (!first) { MessageBox.Show(UiLanguage.Text("이미 실행 중입니다.")); return 1; }
    Application.EnableVisualStyles();
    Application.SetCompatibleTextRenderingDefault(false);
    string verification = null;
    if (args.Length == 1 && args[0] == "--verify-login")
     verification = Path.Combine(Engine.Data, "verification-" + Guid.NewGuid().ToString("N"));
    else if (args.Length == 2 && args[0] == "--resume-verification") {
     if (!System.Text.RegularExpressions.Regex.IsMatch(args[1], @"\Averification-[a-f0-9]{32}\z")) return 2;
     verification = Path.Combine(Engine.Data,args[1]);
     if (!Directory.Exists(verification)) return 2;
    }
    Chat previous = null;
    do {
     var current = new Chat(verification, previous == null && args.Length == 1 && args[0] == "--verify-login");
     if (previous != null) previous.CopyDraftsTo(current);
     Application.Run(current);
     previous = current;
    } while (previous.ReloadInterface);
    return 0;
   }
  }
  static int CaptureDesign(string path) {
   Application.EnableVisualStyles();
   Application.SetCompatibleTextRenderingDefault(false);
   using (var sample = new Chat(designPreview:true)) {
    sample.Show();
    Application.DoEvents();
    using (var image = new System.Drawing.Bitmap(sample.Width,sample.Height)) {
     sample.DrawToBitmap(image,new System.Drawing.Rectangle(0,0,image.Width,image.Height));
     image.Save(path,System.Drawing.Imaging.ImageFormat.Png);
    }
   }
   return 0;
  }
 }
}
