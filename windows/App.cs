using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed class Composer : TextBox {
  bool composing;
  public Action Submit;
  protected override void WndProc(ref Message message) {
   if (message.Msg == 0x10d) composing = true;
   base.WndProc(ref message);
   if (message.Msg == 0x10e || message.Msg == 8) composing = false;
  }
  protected override bool ProcessCmdKey(ref Message message, Keys keys) {
   if (keys != Keys.Enter || composing) return base.ProcessCmdKey(ref message, keys);
   if ((message.LParam.ToInt64() & (1L << 30)) == 0 && Submit != null) BeginInvoke(Submit);
   return true;
  }
 }
 sealed partial class Chat : Form {
  readonly Engine engine;
  readonly Translator translator;
  readonly CancellationTokenSource lifetime = new CancellationTokenSource();
  CancellationToken Cancel { get { return lifetime.Token; } }
  readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 3500 };
  readonly System.Windows.Forms.Timer messageTimer = new System.Windows.Forms.Timer { Interval = 1000 };
  bool refreshingMessages;
  readonly ListBox rooms = new StableRoomList { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = 84, IntegralHeight = false, BackColor = Color.FromArgb(248,250,249) };
  readonly Panel messages = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Color.FromArgb(246,247,246) };
  readonly Composer draft = new Composer { Dock = DockStyle.Fill, Multiline = true, AcceptsReturn = true, ScrollBars = ScrollBars.Vertical };
  readonly Composer preview = new Composer { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ForeColor = Color.DarkGreen, ScrollBars = ScrollBars.Vertical };
  readonly Label title = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(12, 0, 0, 0) };
  readonly Label status = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
  readonly Button login = new Button { Text = UiLanguage.Text("QR 로그인"), AutoSize = true, Enabled = false };
  readonly Button send = new PillButton();
  readonly Button attach = new PillButton();
  readonly Dictionary<string, string> translations = new Dictionary<string, string>();
  readonly TranslationStore translationStore;
  string translationOwner;
  readonly Dictionary<string, string> acknowledged = new Dictionary<string, string>();
  readonly HashSet<string> pendingTranslations = new HashSet<string>();
  readonly string[] languages = { "KO", "EN-US", "ZH-HANS" };
  List<IDictionary<string, object>> shown = new List<IDictionary<string, object>>();
  string account, room, prepared, rendered, loginPath;
  readonly Dictionary<string, Tuple<string,string>> unresolved = new Dictionary<string, Tuple<string,string>>();
  int incoming = 0, outgoing = 1, revision;
  bool connected, loading, busy, listing, automatic, closing;
  bool approvedSession;
  bool checkingSession;
  public bool ReloadInterface { get; private set; }
  public void CopyDraftsTo(Chat next) {
   foreach (var entry in drafts) next.drafts.Add(entry.Key, entry.Value);
   foreach (var entry in draftMembers) next.draftMembers.Add(entry.Key, entry.Value);
   foreach (var entry in unresolved) next.unresolved.Add(entry.Key, entry.Value);
   next.room = room;
   next.draft.Text = draft.Text;
   next.prepared = prepared;
   next.preview.ReadOnly = preview.ReadOnly;
   next.preview.Text = preview.Text;
   next.quotedMessage = quotedMessage;
   next.quotedRoom = quotedRoom;
   next.shown = new List<IDictionary<string,object>>(shown);
  }
  string AccountPath { get { return "/accounts/" + Engine.Part(account); } }
  string RoomPath(string id) { return AccountPath + "/threads/" + Engine.Part(id); }
  sealed class Room {
   public string Id, Name, Version, Unread, Preview, Time;
   public override string ToString() { return Name + (Unread != "" && Unread != "0" ? "  (" + Unread + ")" : ""); }
  }
  public Chat(string verificationDirectory = null, bool openQr = false, bool designPreview = false) {
   engine = new Engine(verificationDirectory);
   translator = new Translator(!designPreview);
   if (!designPreview) translationStore = new TranslationStore(verificationDirectory ?? Engine.Data);
   Text = "WeChat Native Translator · Windows v" + Package.Version;
   using (var stream = typeof(Chat).Assembly.GetManifestResourceStream("app.icon"))
    if (stream != null) Icon = new Icon(stream);
   Width = 900; Height = 760; MinimumSize = new Size(760, 480);
   BackColor = Color.FromArgb(236,246,240);
   Padding = new Padding(1,6,1,1);
   Font = new Font("맑은 고딕", 10);
   RoundedUi.ApplyPrimary(login);
   RoundedUi.ApplyPrimary(send);
   send.Text = "\uE724"; send.AccessibleName = UiLanguage.Text("전송");
   RoundedUi.ApplyButton(attach);
   rooms.DrawItem += DrawRoom;
   if (!designPreview) BindRoomListDeletion(verificationDirectory ?? Engine.Data);
   if (designPreview) automatic=true; else LoadSettings();
   var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = Padding.Empty };
   body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 86));
   body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 270));
   body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
   var side = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Margin = Padding.Empty, Padding = new Padding(14,8,14,6), BackColor = rooms.BackColor };
   side.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
   side.RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
   side.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
   var search = new TextBox { Dock = DockStyle.Top, AccessibleName = UiLanguage.Text("대화방 검색"), Margin = Padding.Empty };
   search.TextChanged += (s,e) => Populate(search.Text);
   var searchTip = new ToolTip();
   searchTip.SetToolTip(search, UiLanguage.Text("이름 검색 · Enter로 전체 메시지 검색"));
   search.Disposed += (s,e) => searchTip.Dispose();
   search.KeyDown += async (s,e) => {
    if (e.KeyCode != Keys.Enter) return;
    e.SuppressKeyPress = true;
    await Run(() => SearchMessages(true, search.Text));
   };
   roomSearch = search;
   RoundedUi.ApplySearch(search);
   side.Controls.Add(BuildRoomSearch(search), 0, 0);
   side.Controls.Add(BuildFilters(), 0, 1); side.Controls.Add(rooms, 0, 2);
   body.Controls.Add(BuildRail(),0,0);
   body.Controls.Add(side, 1, 0);
   var pane = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 6, ColumnCount = 1, Margin = Padding.Empty, BackColor=messages.BackColor };
   foreach (int height in new[] { 64, 54, 0, 0, 62, 22 })
    pane.RowStyles.Add(new RowStyle(pane.RowStyles.Count == 2 ? SizeType.Percent : SizeType.Absolute, pane.RowStyles.Count == 2 ? 100 : height));
   var actions = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount=4, RowCount=1, Margin=new Padding(10,5,10,3), Padding=new Padding(6,3,6,3), BackColor = Color.White };
   foreach (int column in new[] { 43, 0, 44, 44 })
    actions.ColumnStyles.Add(new ColumnStyle(column == 0 ? SizeType.Percent : SizeType.Absolute, column == 0 ? 100 : column));
   actions.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   actions.Resize += (s,e) => RoundedUi.Round(actions,24);
   attach.Text = "\uE723"; attach.Font = new Font("Segoe MDL2 Assets",15); attach.AccessibleName=UiLanguage.Text("파일 보내기"); attach.Dock=DockStyle.Fill;
   send.Font = new Font("Segoe MDL2 Assets",15); send.Dock=DockStyle.Fill;
   var translate = new PillButton { Text="文ᴬ", AccessibleName=UiLanguage.Text("번역 미리보기"), Dock=DockStyle.Fill };
   RoundedUi.ApplyButton(translate,true);
   translate.Click += async (s,e) => { if (prepared == null) await Submit(); else preview.Focus(); };
   actions.Controls.Add(attach,0,0); actions.Controls.Add(ComposerSurface(draft),1,0);
   actions.Controls.Add(translate,2,0); actions.Controls.Add(send,3,0);
   pane.Controls.Add(BuildHeader(), 0, 0);
   pane.Controls.Add(BuildTranslationBar(),0,1); pane.Controls.Add(messages, 0, 2);
   messages.Resize += (s,e) => { if (shown.Count > 0) Render(); };
   pane.Controls.Add(actions, 0, 3);
   pane.Controls.Add(ComposerSurface(preview), 0, 4);
   Action sizeComposer = () => {
    if (draft.ClientSize.Width < 20) return;
    int cap = Math.Max(80, Math.Min(240, ClientSize.Height / 3));
    pane.RowStyles[3].Height = Math.Min(cap, Math.Max(62, TextRenderer.MeasureText(
     draft.Text + " ", draft.Font, new Size(Math.Max(20,draft.ClientSize.Width - 16), int.MaxValue),
     TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix).Height + 36));
    pane.RowStyles[4].Height = preview.TextLength == 0 ? 0 : Math.Min(cap, Math.Max(60, TextRenderer.MeasureText(
     preview.Text, preview.Font, new Size(Math.Max(20,preview.ClientSize.Width - 16), int.MaxValue),
     TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix).Height + 24));
    ScrollToLatest();
   };
   draft.TextChanged += (s,e) => sizeComposer();
   draft.Resize += (s,e) => sizeComposer();
   preview.TextChanged += (s,e) => sizeComposer();
   pane.Controls.Add(status, 0, 5);
   sizeComposer();
   body.Controls.Add(pane, 2, 0); Controls.Add(body);
   title.Text = UiLanguage.Text("대화방을 선택하세요");
   status.Text = UiLanguage.Text("Enter 번역 → Enter 전송 · Shift+Enter 줄바꿈");
   send.Click += async (s,e) => await Submit();
   draft.Submit = async () => { if (draft.Focused && !closing) await Submit(); };
   preview.Submit = async () => { if (preview.Focused && !closing && prepared != null) await Submit(); };
   draft.TextChanged += (s,e) => { revision++; ClearPreview(); };
   if (!designPreview) BindMentions();
   login.Click += async (s,e) => await Run(Login);
   attach.Click += async (s,e) => await Run(SendAttachment);
   BuildMessageMenu();
   rooms.SelectedIndexChanged += async (s,e) => {
    if (listing || busy) return;
    var selected = rooms.SelectedItem as Room;
    if (selected == null || selected.Id == room) return;
    if (room != null) drafts[room] = draft.Text;
    room = selected.Id; title.Text = selected.Name; headerAvatar.Invalidate(); draft.Text = drafts.ContainsKey(room) ? drafts[room] : "";
    ClearPreview(); shown.Clear(); ResetHistory(); rendered = null; ClearMessageCards();
    await Task.WhenAll(RefreshMessages(),RefreshSelectedRoomName(selected));
   };
   messageTimer.Tick += async (s,e) => await RefreshMessages();
   timer.Tick += async (s,e) => {
    if (busy || closing) return;
    if (connected) {
     try { if (!await VerifyConnection()) return; }
     catch (Exception) { return; }
    }
    if (!connected) {
     await CheckRestoredSession();
     if (!connected) return;
    }
    await RefreshChat();
    await RefreshDirectoryIfDue();
    await SyncMessagesIfDue();
   };
   Shown += async (s,e) => {
    if (designPreview) { ShowDesignExample(); return; }
    if (verificationDirectory == null) EnsureDeepLKey();
    if (closing) return;
    await Run(Start);
    if (closing) return;
    timer.Start();
    messageTimer.Start();
    if (openQr && login.Enabled) await Run(Login);
   };
   FormClosed += (s,e) => { closing = true; timer.Stop(); messageTimer.Dispose(); lifetime.Cancel(); engine.Dispose(); translator.Dispose(); foreach (var image in avatars.Values) image.Dispose(); };
  }
  async Task CheckRestoredSession() {
   if (account == null || busy || checkingSession || closing) return;
   checkingSession = true;
   try {
    var profile = await engine.Json(AccountPath, Cancel);
    if (closing || busy || Engine.Get(profile, "id") != account) return;
    if (Engine.Get(profile, "authenticated").Equals("true", StringComparison.OrdinalIgnoreCase)) {
     translationOwner = Engine.Get(profile, "ownUsername");
     connected = true;
     login.Enabled = false;
     status.Text = UiLanguage.Text("연결됨");
    } else if (Engine.Get(profile,"connection") == "reconnecting") {
     status.Text = UiLanguage.Text("저장된 세션에 다시 연결 중…");
    }
   } catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing && !busy) status.Text = error.Message; }
   finally { checkingSession = false; }
  }
  readonly TextBox roomSearch;
  readonly Dictionary<string, string> drafts = new Dictionary<string, string>();
  List<Room> inventory = new List<Room>();
  void ClearPreview() {
   prepared = null;
   preview.ReadOnly = true;
   preview.Text = "";
  }
  async Task Run(Func<Task> action) {
   if (busy || closing) return;
   busy = true; send.Enabled = attach.Enabled = rooms.Enabled = roomSearch.Enabled = false;
   try { await action(); }
   catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing) status.Text = error.Message; }
   finally {
    busy = false;
    if (!closing) send.Enabled = attach.Enabled = rooms.Enabled = roomSearch.Enabled = true;
   }
  }
  async Task Start() {
   await engine.Start(Cancel);
   var existing = Engine.Items(await engine.Json("/accounts", Cancel)).FirstOrDefault(x => Engine.Get(x, "id") == "personal");
   if (existing == null) existing = await engine.Json("/accounts", Cancel, new { id = "personal" });
   account = Engine.Get(existing, "id");
   if (account != "personal") throw new IOException(UiLanguage.Text("계정 응답을 확인할 수 없습니다."));
   connected = Engine.Get(existing, "authenticated").Equals("true", StringComparison.OrdinalIgnoreCase);
   translationOwner = Engine.Get(existing, "ownUsername");
   login.Enabled = !connected;
   status.Text = connected ? UiLanguage.Text("연결됨") : UiLanguage.Text("휴대폰 WeChat에서 QR 로그인을 승인하세요.");
  }
  async Task Login() {
   login.Enabled = false;
   using (var dialog = new Form { Text = UiLanguage.Text("WeChat QR 로그인"), Width = 360, Height = 410, StartPosition = FormStartPosition.CenterParent }) {
    var qr = new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.White };
    var hint = new Label { Text = UiLanguage.Text("휴대폰 WeChat으로 QR을 스캔하세요."), Dock = DockStyle.Bottom, Height = 42, TextAlign = ContentAlignment.MiddleCenter };
    dialog.Controls.Add(qr); dialog.Controls.Add(hint);
    using (var stop = CancellationTokenSource.CreateLinkedTokenSource(Cancel)) {
     dialog.FormClosed += (s,e) => stop.Cancel();
     try {
      var operation = await engine.Json(AccountPath + "/auth/login", Cancel, new { }, Guid.NewGuid().ToString("N"));
      var id = Engine.Get(operation, "id");
      if (id == "") throw new IOException(UiLanguage.Text("로그인 요청 ID를 받지 못했습니다."));
      loginPath = AccountPath + "/operations/" + Engine.Part(id);
      dialog.Show(this);
      string generation = null;
      for (int i = 0; i < 180; ++i) {
       stop.Token.ThrowIfCancellationRequested();
       var state = Engine.Get(operation, "state");
       if (state == "succeeded") {
        approvedSession = true;
        hint.Text = UiLanguage.Text("승인 완료 · 계정과 대화 목록 확인 중…");
        await VerifyApprovedSession(stop.Token);
        connected = true;
        break;
       }
       if (new[] { "failed", "cancelled", "expired", "rejected", "needs_login" }.Contains(state)) throw new IOException(UiLanguage.Text("QR 로그인 ") + state);
       var result = Engine.Object(operation, "result");
       var next = Engine.Get(result, "qrGeneration");
       if (next == "") next = "1";
       if (Engine.Get(result, "qrAvailable").Equals("true", StringComparison.OrdinalIgnoreCase) && generation != next) {
        using (var res = await engine.Request(loginPath + "/qr?generation=" + Engine.Part(next), stop.Token)) {
         await res.Content.LoadIntoBufferAsync(1024 * 1024);
         var bytes = await res.Content.ReadAsByteArrayAsync();
         if (!bytes.Take(8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) throw new IOException(UiLanguage.Text("QR 이미지 응답이 올바르지 않습니다."));
         using (var stream = new MemoryStream(bytes))
         using (var image = Image.FromStream(stream)) {
          var old = qr.Image; qr.Image = new Bitmap(image); if (old != null) old.Dispose();
         }
        }
        generation = next;
       }
       await Task.Delay(1000, stop.Token);
       operation = await engine.Json(loginPath, stop.Token);
      }
      if (!connected) throw new IOException(UiLanguage.Text("QR 로그인 시간이 만료됐습니다."));
      status.Text = UiLanguage.Text("연결됨");
     } catch (Exception) {
      if (!approvedSession && loginPath != null && !closing) CancelLogin(loginPath);
      throw;
     } finally {
      loginPath = null;
      if (!dialog.IsDisposed) dialog.Close();
      if (qr.Image != null) qr.Image.Dispose();
      if (!closing) {
       FinishLoginAttempt();
      }
     }
    }
   }
  }
  async Task VerifyApprovedSession(CancellationToken cancel) {
   for (int attempt = 0; attempt < 8; ++attempt) {
    try {
     var profile = await engine.Json(AccountPath, cancel);
     if (Engine.Get(profile, "id") == account &&
         Engine.Get(profile, "authenticated").Equals("true", StringComparison.OrdinalIgnoreCase)) {
      await engine.Pages(AccountPath + "/threads", cancel);
      translationOwner = Engine.Get(profile, "ownUsername");
      return;
     }
    } catch (HttpRequestException error) {
     if (attempt == 7) throw new IOException(UiLanguage.Text("휴대폰 승인 완료 · 계정 또는 대화 목록 확인 실패: ") + error.Message);
    }
    await Task.Delay(750, cancel);
   }
   throw new IOException(UiLanguage.Text("휴대폰 승인 완료 · 엔진에서 계정 인증 상태를 확인하지 못했습니다."));
  }
  async void CancelLogin(string path) {
   using (var timeout = new CancellationTokenSource(2500)) {
    try { using (await engine.Request(path, timeout.Token, HttpMethod.Delete)) {} }
    catch (HttpRequestException) {}
    catch (OperationCanceledException) {}
    catch (ObjectDisposedException) {}
   }
  }
  void Populate(string search) {
   if (loadRemovedRooms != null) loadRemovedRooms();
   var candidates = string.IsNullOrWhiteSpace(search) ? FilteredRooms() :
    inventory.Concat(directory).GroupBy(x => x.Id).Select(group => group.First());
   var list = candidates.Where(x => !removedRooms.Contains(x.Id) &&
    (x.Name.IndexOf(search, StringComparison.CurrentCultureIgnoreCase) >= 0 ||
     RoomName(x).IndexOf(search,StringComparison.CurrentCultureIgnoreCase) >= 0 ||
     (x.Preview ?? "").IndexOf(search,StringComparison.CurrentCultureIgnoreCase) >= 0))
    .Select(x => new Room {Id=x.Id, Name=RoomName(x), Version=x.Version, Unread=x.Unread, Preview=x.Preview,Time=x.Time}).ToArray();
   if (rooms.Items.Count == list.Length && rooms.Items.Cast<Room>().Zip(list,(a,b) =>
    a.Id==b.Id && a.Name==b.Name && a.Unread==b.Unread && a.Time==b.Time && a.Preview==b.Preview).All(equal => equal)) return;
   listing = true;
   int top = rooms.TopIndex;
   rooms.BeginUpdate();
   try {
    for (int index = 0; index < list.Length; index++) {
     if (index >= rooms.Items.Count) rooms.Items.Add(list[index]);
     else if (((Room)rooms.Items[index]).Id != list[index].Id ||
              ((Room)rooms.Items[index]).ToString() != list[index].ToString() ||
              ((Room)rooms.Items[index]).Time != list[index].Time ||
              ((Room)rooms.Items[index]).Preview != list[index].Preview)
      rooms.Items[index] = list[index];
     else ((Room)rooms.Items[index]).Version = list[index].Version;
    }
    while (rooms.Items.Count > list.Length) rooms.Items.RemoveAt(rooms.Items.Count - 1);
    rooms.SelectedIndex = Array.FindIndex(list, x => x.Id == room);
    if (rooms.Items.Count > 0) rooms.TopIndex = Math.Min(top, rooms.Items.Count - 1);
    var current = rooms.SelectedItem as Room;
    if (current != null) title.Text = current.Name;
   } finally { rooms.EndUpdate(); listing = false; }
  }
  async Task RefreshChat(bool manual = false) {
   if (!connected || loading || (busy && !manual) || closing) return;
   loading = true;
   try {
    var rows = await engine.Pages(AccountPath + "/threads", Cancel);
    inventory = rows.Select(x => {
     var id = Engine.Get(x, "id"); var name = Engine.Get(x, "displayName");
     var last = Engine.Object(x,"lastMessage");
     return new Room { Id = id, Name = id == "filehelper" ? UiLanguage.Text("파일 전송") : name != "" ? name : id,
      Unread = Engine.Get(x, "unreadCount"), Version = Engine.Get(x, "readStateVersion"),
      Preview=last == null ? "" : Engine.Get(last,"text"), Time=last == null ? "" : ChatTime(Engine.Get(last,"createdAt")) };
    }).ToList();
    if (closing || (busy && !manual)) return;
    Populate(roomSearch.Text);
    LoadAvatarsInBackground(room);
   } catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing && !busy) status.Text = error.Message; }
   finally { loading = false; }
  }
  async Task RefreshMessages() {
   if (!connected || refreshingMessages || busy || closing || room == null) return;
   refreshingMessages = true;
   try {
    var idNow = room;
    var row = inventory.FirstOrDefault(x => x.Id == idNow);
    var result = await engine.Json(RoomPath(idNow) + "/messages?limit=80", Cancel);
    if (room != idNow || closing || busy) return;
    var latest = Engine.Items(result).Reverse().ToList();
    if (!historyExtended) olderCursor = Engine.Get(result,"nextCursor");
    shown = MergeHistory(shown, latest);
    UpdateHistoryButton();
    Render();
    LoadAvatarsInBackground(idNow);
    if (automatic && translator.Key != "") TranslateInBackground(idNow);
    if (row != null && shown.Count > 0 && room == idNow && !busy && ContainsFocus && row.Version != "" && row.Unread != "0") {
     string last;
     if (!acknowledged.TryGetValue(idNow, out last) || last != row.Version) {
      var receipt = await engine.Json(RoomPath(idNow) + "/read-state", Cancel, new { expectedVersion = row.Version });
      if (Engine.Get(receipt, "threadId") == idNow) acknowledged[idNow] = row.Version;
     }
    }
    if (automatic && translator.Key == "" && shown.Any(ShowGroupSender) && status.Text == UiLanguage.Text("연결됨"))
     status.Text = UiLanguage.Text("자동 번역에 DeepL API 키가 필요합니다 · 언어 설정");
   } catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing && !busy) status.Text = error.Message; }
   finally { refreshingMessages = false; }
  }
  string TranslationKey(IDictionary<string, object> row) {
   return (translationOwner ?? "") + "\n" + room + "\n" + Engine.Get(row, "id") + "\n" + languages[incoming] + "\n" + Body(row);
  }
  string OriginalSendKey(string destination, string serverId) {
   return (translationOwner ?? "") + "\n" + destination + "\nsent-original\n" + serverId;
  }
  string MessageTranslation(IDictionary<string,object> row) {
   if (Engine.Get(row,"direction") == "outgoing") {
    var serverId = Engine.Get(row,"serverId");
    if (serverId != "") {
     var original = CachedTranslation(OriginalSendKey(room,serverId));
     if (original != null) return original;
    }
   }
   return CachedTranslation(TranslationKey(row));
  }
  string CachedTranslation(string key) {
   string value;
   if (!translations.TryGetValue(key, out value)) {
    value = translationStore != null && !string.IsNullOrEmpty(translationOwner) ? translationStore.Read(key) : null;
    translations[key] = value;
   }
   return value;
  }
  static string Body(IDictionary<string, object> item) {
   var quote = Engine.Object(item, "quote");
   var body = Engine.Get(item, "body");
   if (quote == null) return body;
   var quoted = Engine.Get(quote, "embeddedText");
   if (quoted == "") quoted = Engine.Get(quote, "text");
   return quoted == "" ? body : body + "\n↳ " + Engine.Get(quote, "senderName") + " " + quoted;
  }
  async Task TranslateIncoming(string id) {
   foreach (var item in shown.AsEnumerable().Reverse().ToArray()) {
    if (room != id || busy || closing || !automatic) return;
    var type = Engine.Get(item, "type");
    if (Engine.Object(item,"recall") != null || (type != "1" && !(type == "49" && Engine.Get(item, "appMessageType") == "57"))) continue;
    var key = TranslationKey(item);
    if (MessageTranslation(item) != null || !pendingTranslations.Add(key)) continue;
    try {
     var source = Body(item);
     if (string.IsNullOrWhiteSpace(source)) continue;
     var owner = translationOwner;
     var translated = await translator.Translate(source, languages[incoming], Cancel);
     if (closing) return;
     translations[key] = translated;
     if (room == id) Render();
     try {
      if (!string.IsNullOrEmpty(owner)) translationStore.Save(key, translated);
     } catch (IOException) { status.Text = UiLanguage.Text("번역문을 컴퓨터에 저장하지 못했습니다."); }
     catch (UnauthorizedAccessException) { status.Text = UiLanguage.Text("번역문을 컴퓨터에 저장하지 못했습니다."); }
     catch (System.Security.Cryptography.CryptographicException) { status.Text = UiLanguage.Text("번역문을 컴퓨터에 저장하지 못했습니다."); }
    } finally { pendingTranslations.Remove(key); }
    break;
   }
  }
  bool translatingIncoming;
  async void TranslateInBackground(string id) {
   if (translatingIncoming) return;
   translatingIncoming = true;
   try { await TranslateIncoming(id); }
   catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing && room == id) status.Text = UiLanguage.Text("자동 번역: ") + error.Message; }
   finally { translatingIncoming = false; }
  }
  static string AttachmentLabel(IDictionary<string, object> row) {
   switch (Engine.Get(row, "type")) {
    case "3": return UiLanguage.Text("사진"); case "34": return UiLanguage.Text("음성"); case "43": case "62": return UiLanguage.Text("동영상"); case "47": return UiLanguage.Text("스티커");
    case "49": return Engine.Get(row, "appMessageType") == "6" ? UiLanguage.Text("파일") : "";
    default: return "";
   }
  }
  void Render(bool preserveViewport = true) {
   if (rebuildingMessages) return;
   var viewport = CaptureMessageViewport();
   var rows = shown.Where(row => !hiddenMessages.Contains(Engine.Get(row, "id"))).Select(row => {
    var translated = Engine.Object(row, "recall") == null ? MessageTranslation(row) : null;
    var label = AttachmentLabel(row);
    var type = Engine.Get(row, "type");
    var senderId = Engine.Get(row,"senderId");
    var groupIncoming = room != null && room.EndsWith("@chatroom", StringComparison.Ordinal) && ShowGroupSender(row);
    return new { Id = Engine.Get(row, "id"), Out = Engine.Get(row, "direction") == "outgoing",
     Sender = groupIncoming ? SenderName(row, senderId) : "", Time=ChatTime(Engine.Get(row,"createdAt")), Date=ChatDate(Engine.Get(row,"createdAt")),
     SenderId = Engine.Get(row,"direction") == "outgoing" ? ownAvatarId : (groupIncoming ? senderId : room ?? ""),
     Text = Engine.Object(row, "recall") != null ? UiLanguage.Text("회수된 메시지") : label != "" ? "[" + label + "]" : type == "1" || (type == "49" && Engine.Get(row, "appMessageType") == "57") ? Body(row) : UiLanguage.Text("[지원하지 않는 메시지 유형]"), Translation = translated };
   }).ToArray();
   var signature = messages.ClientSize.Width + "|" + messages.ClientSize.Height + "|" + string.Join("\n", rows.Select(x => x.Id + "|" + x.Out + "|" + x.Text + "|" + x.Translation + "|" + x.Sender + "|" + x.SenderId + "|" + avatars.ContainsKey(x.SenderId)));
   if (signature == rendered) return;
   rendered = signature;
   rebuildingMessages = true;
   messages.SuspendLayout();
   try {
    ClearMessageCards();
    int y = 12;
    DateTime? day = null;
    foreach (var entry in rows) {
     if (entry.Date.HasValue && entry.Date != day) {
      day = entry.Date;
      var divider = new Label { Text=day.Value.Date==DateTime.Today ? UiLanguage.Text("오늘") : day.Value.ToString("yyyy.MM.dd"),
       TextAlign=ContentAlignment.MiddleCenter,ForeColor=Color.DimGray,Bounds=new Rectangle((messages.ClientSize.Width-90)/2,y,90,24) };
      messages.Controls.Add(divider);
      y += 38;
     }
     y += AddMessageCard(y, entry.Id, entry.Out, entry.SenderId, entry.Sender, entry.Text, entry.Translation, entry.Time);
    }
    messages.AutoScrollMinSize = new Size(0,y);
   } finally { messages.ResumeLayout(); rebuildingMessages = false; }
   if (preserveViewport) RestoreMessageViewport(viewport);
   else ScrollToLatest();
  }
  async Task Submit() {
   await Run(async () => {
    if (!connected || room == null || rooms.SelectedItem == null) throw new IOException(UiLanguage.Text("로그인한 뒤 대화방을 선택하세요."));
    if (!await VerifyConnection()) return;
    var source = draft.Text;
    if (string.IsNullOrWhiteSpace(source)) return;
    var id = room;
    var mentions = DraftMentions(id, source);
    var prefix = string.Concat(mentions.Select(member => member.Token));
    var body = source.Substring(prefix.Length).Trim();
    if (mentions.Count > 0 && body.Length == 0) throw new IOException(UiLanguage.Text("멘션 뒤에 보낼 내용을 입력하세요."));
    if (prepared == null) {
     if (!EnsureDeepLKey()) return;
     int version = revision, lang = outgoing;
     status.Text = UiLanguage.Text("번역 중…");
     var result = await translator.Translate(mentions.Count == 0 ? source : body, languages[lang], Cancel);
     if (closing || revision != version || id != room || lang != outgoing) return;
     prepared = result;
     preview.ReadOnly = false;
     preview.Text = prefix + result;
     status.Text = UiLanguage.Text("번역문을 확인한 뒤 Enter를 누르세요.");
     return;
    }
    var displayed = preview.Text;
    if (prefix.Length > 0 && !displayed.StartsWith(prefix, StringComparison.Ordinal))
     throw new IOException(UiLanguage.Text("멘션은 메시지 입력창에서 수정하세요."));
    var text = displayed.Substring(prefix.Length).Trim();
    if (text.Length == 0) throw new IOException(UiLanguage.Text("전송할 번역문을 입력하세요."));
    var originalRevision = revision;
    status.Text = UiLanguage.Text("전송 상태 확인 중…");
    bool sendFailed = false;
    try {
     var payload = new Dictionary<string,object> { { "threadId", id }, { "text", text } };
     if (mentions.Count > 0) payload["mentions"] = new { userIds = mentions.Select(member => member.Id).ToArray() };
     if (quotedRoom == id && quotedMessage != null) {
      var current = shown.FirstOrDefault(m => Engine.Get(m, "id") == Engine.Get(quotedMessage, "id"));
      if (!CanQuote(current)) throw new IOException(UiLanguage.Text("인용 메시지 상태를 확인할 수 없습니다."));
      payload["quote"] = new { messageId = Engine.Get(current, "id"), serverId = Engine.Get(current, "serverId") };
     }
     var identity = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(payload);
     Tuple<string,string> attempt;
     if (!unresolved.TryGetValue(id, out attempt) || attempt.Item1 != identity)
      unresolved[id] = attempt = Tuple.Create(identity, Guid.NewGuid().ToString("N"));
     var result = await engine.Json(AccountPath + "/sends", Cancel, payload, attempt.Item2);
     var sendId = Engine.Get(result, "id");
     for (int i = 0; i < 10; ++i) {
      if (sendId == "" || Engine.Get(result, "destination") != id) throw new IOException(UiLanguage.Text("대상 확인 실패"));
      var state = Engine.Get(result, "state");
      if (state != "queued" && state != "submitting") break;
      await Task.Delay(500, Cancel);
      result = await engine.Json(AccountPath + "/sends/" + Engine.Part(sendId), Cancel);
     }
     if (Engine.Get(result, "destination") != id || Engine.Get(result, "id") != sendId) throw new IOException(UiLanguage.Text("전송 미확인"));
     var finalState = Engine.Get(result, "state");
     if (finalState == "failed" || finalState == "cancelled") {
      unresolved.Remove(id);
      preview.Text = displayed;
      status.Text = UiLanguage.Text("위챗에서 전송을 수락하지 않았습니다.");
      return;
     }
     if (finalState != "accepted") throw new IOException(UiLanguage.Text("전송 미확인"));
     var acceptedServerId = Engine.Get(result,"serverId");
     if (acceptedServerId != "") {
      var originalKey = OriginalSendKey(id,acceptedServerId);
      translations[originalKey] = source;
      try { if (translationStore != null) translationStore.Save(originalKey,source); }
      catch (IOException) { status.Text = UiLanguage.Text("번역문을 컴퓨터에 저장하지 못했습니다."); }
      catch (UnauthorizedAccessException) { status.Text = UiLanguage.Text("번역문을 컴퓨터에 저장하지 못했습니다."); }
      catch (System.Security.Cryptography.CryptographicException) { status.Text = UiLanguage.Text("번역문을 컴퓨터에 저장하지 못했습니다."); }
     }
     unresolved.Remove(id);
     quotedMessage = null;
     ClearPreview();
     if (revision == originalRevision) draft.Clear();
     status.Text = UiLanguage.Text("전송 요청 확인");
    } catch (Exception) {
     if (closing) return;
     preview.Text = displayed;
     status.Text = UiLanguage.Text("전송 결과를 확인하지 못했습니다. 대화 내용을 먼저 확인하세요.");
     sendFailed = true;
    }
    if (sendFailed) { try { await VerifyConnection(); } catch (Exception) {} }
   });
   if (!closing && ContainsFocus) {
    if (prepared != null) preview.Focus();
    else draft.Focus();
   }
  }
 }
}
