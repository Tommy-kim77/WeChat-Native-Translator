using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  int filterIndex;
  readonly List<Room> directory = new List<Room>();
  readonly Dictionary<string,string> englishNames = new Dictionary<string,string>();
  readonly Dictionary<string,string> wechatContactNames = new Dictionary<string,string>();
  readonly Dictionary<string,string> groupNames = new Dictionary<string,string>();
  readonly Dictionary<string,DateTime> groupNameAttempts = new Dictionary<string,DateTime>();
  static bool IsGroupName(string name, string id) {
   name = (name ?? "").Trim();
   return name.Length > 0 && !name.Equals(id,StringComparison.OrdinalIgnoreCase) &&
    !name.EndsWith("@chatroom",StringComparison.OrdinalIgnoreCase) && !name.All(char.IsDigit);
  }
  static string ReadGroupName(IDictionary<string,object> row, string id) {
   return new[]{"remark","displayName","name"}.Select(field => Engine.Get(row,field).Trim())
    .FirstOrDefault(name => IsGroupName(name,id));
  }
  string RoomName(Room entry) {
   string name;
   if (IsGroup(entry)) {
    if (groupNames.TryGetValue(entry.Id,out name)) return name;
    return IsGroupName(entry.Name,entry.Id) ? entry.Name : UiLanguage.Text("이름 미확인 그룹");
   }
   if (wechatContactNames.TryGetValue(entry.Id,out name)) return name;
   if (englishNames.TryGetValue(entry.Id,out name)) return name;
   var contact = directory.FirstOrDefault(x => x.Id == entry.Id && x.Name != x.Id);
   return contact == null ? entry.Name : contact.Name;
  }
  readonly Dictionary<string,DateTime> contactNameAttempts = new Dictionary<string,DateTime>();
  async Task RefreshSelectedRoomName(Room selected) {
   if (IsGroup(selected)) { await RefreshSelectedGroupName(selected); return; }
   if (!connected || selected.Id == "filehelper") return;
   DateTime next;
   if (contactNameAttempts.TryGetValue(selected.Id,out next) && next > DateTime.UtcNow) return;
   contactNameAttempts[selected.Id] = DateTime.UtcNow.AddMinutes(5);
   try {
    var lookup = await engine.Json(AccountPath + "/contacts/lookup",Cancel,new { ids = new[] {selected.Id} });
    var item = Engine.Items(lookup).SingleOrDefault();
    var results = lookup["results"] as System.Collections.IEnumerable;
    var name = Engine.Get(item,"displayName").Trim();
    if (results == null || !results.Cast<object>().Select(Convert.ToString).SequenceEqual(new[]{"0"}) ||
        Engine.Get(item,"id") != selected.Id || name == "" || name == selected.Id || closing) return;
    wechatContactNames[selected.Id] = name;
    Populate(roomSearch.Text);
   } catch (OperationCanceledException) {}
   catch (Exception error) {
    if (!closing && room == selected.Id && !busy) status.Text = UiLanguage.Text("위챗 이름 조회 실패: ") + error.Message;
   }
  }
  async Task RefreshSelectedGroupName(Room selected) {
   if (!connected || !IsGroup(selected) || RoomName(selected) != UiLanguage.Text("이름 미확인 그룹")) return;
   DateTime next;
   if (groupNameAttempts.TryGetValue(selected.Id,out next) && next > DateTime.UtcNow) return;
   groupNameAttempts[selected.Id] = DateTime.UtcNow.AddMinutes(5);
   try {
    var path = AccountPath + "/groups/" + Engine.Part(selected.Id);
    await AwaitMetadata(await engine.Json(path + "/refresh",Cancel,new { }));
    var name = ReadGroupName(await engine.Json(path,Cancel),selected.Id);
    if (closing || name == null) return;
    groupNames[selected.Id] = name;
    Populate(roomSearch.Text);
   } catch (OperationCanceledException) {}
   catch (Exception error) {
    if (!closing && room == selected.Id && !busy) status.Text = UiLanguage.Text("그룹 이름 조회 실패: ") + error.Message;
   }
  }
  DateTime nextDirectory;
  bool readingDirectory;
  Button[] railButtons;
  Panel headerAvatar, profileAvatar;
  Control BuildRail() {
   var rail = new FlowLayoutPanel { Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = new Padding(8,13,8,0),
    FlowDirection = FlowDirection.TopDown, WrapContents = false, BackColor = Color.FromArgb(233,245,238) };
   var profile = new Panel { Size=new Size(48,48), Margin=new Padding(10,3,0,15) };
   profileAvatar = profile;
   profile.Paint += (s,e) => DrawAvatar(e.Graphics,profile.ClientRectangle,ownAvatarId,UiLanguage.Text("나"));
   rail.Controls.Add(profile);
   var labels = new[]{UiLanguage.Text("채팅"),UiLanguage.Text("연락처"),UiLanguage.Text("그룹"),UiLanguage.Text("설정")};
   var icons = new[]{"\uE8BD","\uE77B","\uE716","\uE713"};
   railButtons = new Button[labels.Length];
   var tips = new ToolTip();
   rail.Disposed += (s,e) => tips.Dispose();
   for (int i=0;i<labels.Length;i++) {
    var index = i;
    var button = new Button { Text=labels[i], AccessibleName=labels[i], Size=new Size(68,72), TextAlign=ContentAlignment.BottomCenter };
    RoundedUi.ApplyButton(button,i==0);
    button.Margin = new Padding(0,0,0,8);
    button.Padding = new Padding(0,0,0,9);
    button.Font = new Font(Font.FontFamily,9);
    var glyph = icons[i];
    button.Paint += (s,e) => TextRenderer.DrawText(e.Graphics,glyph,railIconFont,new Rectangle(0,6,button.Width,33),
     button.ForeColor,TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    tips.SetToolTip(button,labels[i]);
    button.Click += async (s,e) => {
     if (index==3) Settings();
    else await SelectFilter(index==1 ? 3 : index);
    };
    railButtons[i]=button;
    rail.Controls.Add(button);
   }
   return rail;
  }
  readonly Font railIconFont = new Font("Segoe MDL2 Assets",17);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]
  static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr parameter, string text);
  Control SearchSurface(TextBox input) {
   var surface = new Panel { Dock=DockStyle.Fill, Height=42, Margin=new Padding(0,9,0,8),
    Padding=new Padding(39,10,12,0), BackColor=Color.FromArgb(239,243,241) };
   surface.Paint += (s,e) => TextRenderer.DrawText(e.Graphics,"\uE721",railIconFont,new Point(9,7),Color.DimGray);
   input.HandleCreated += (s,e) => SendMessage(input.Handle,0x1501,IntPtr.Zero,UiLanguage.Text("대화 검색"));
   input.BorderStyle = BorderStyle.None;
   input.BackColor = surface.BackColor;
   surface.Controls.Add(input);
   surface.Resize += (s,e) => RoundedUi.Round(surface,14);
   return surface;
  }
  Control BuildRoomSearch(TextBox input) {
   var row = new TableLayoutPanel { Dock=DockStyle.Fill, ColumnCount=2, RowCount=1, Margin=Padding.Empty };
   row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
   row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,42));
   var refresh = new PillButton { Text="↻", AccessibleName=UiLanguage.Text("WeChat 대화 목록 동기화"), Dock=DockStyle.Fill };
   RoundedUi.ApplyButton(refresh);
   refresh.Margin = new Padding(4,9,0,8);
   refresh.Click += async (s,e) => await Run(SyncRoomNames);
   row.Controls.Add(SearchSurface(input),0,0);
   row.Controls.Add(refresh,1,0);
   return row;
  }
  async Task SyncRoomNames() {
   if (!connected) throw new InvalidOperationException(UiLanguage.Text("WeChat에 로그인한 뒤 동기화하세요."));
   if (readingDirectory) throw new InvalidOperationException(UiLanguage.Text("목록을 불러오는 중입니다. 잠시 뒤 다시 눌러주세요."));
   readingDirectory = true;
   var failed = new List<string>();
   status.Text = UiLanguage.Text("WeChat에서 최근 대화와 방 이름 동기화 중…");
   try {
    foreach (var request in new[] {
     Tuple.Create("/sync", UiLanguage.Text("최근 대화")),
     Tuple.Create("/group-sync", UiLanguage.Text("그룹 이름")),
     Tuple.Create("/contact-sync", UiLanguage.Text("연락처 이름"))
    }) {
     try { await AwaitMetadata(await engine.Json(AccountPath + request.Item1,Cancel,new { })); }
     catch (OperationCanceledException) { throw; }
     catch (Exception) { failed.Add(request.Item2); }
    }
    await RefreshChat(manual:true);
    await ReadDirectory();
    if (!closing) status.Text = failed.Count == 0
     ? UiLanguage.Text("WeChat 동기화 완료 · 최근 대화 ") + inventory.Count + UiLanguage.Text("개")
     : UiLanguage.Text("동기화 실패 · ") + string.Join(", ",failed);
   } finally { readingDirectory = false; }
  }
  Control ComposerSurface(TextBox input) {
   var surface = new Panel { Dock=DockStyle.Fill, BackColor=Color.FromArgb(246,248,247), Padding=new Padding(12,8,12,5) };
   if (input==draft) {
    input.AccessibleName=UiLanguage.Text("한국어로 메시지 입력");
    var hint=new Label { Text=UiLanguage.Text("한국어로 메시지 입력..."), ForeColor=Color.DimGray, AutoSize=true, Location=new Point(11,9), Cursor=Cursors.IBeam };
    surface.Controls.Add(hint);
    hint.Click += (s,e) => input.Focus();
    input.TextChanged += (s,e) => hint.Visible=input.TextLength==0 && !input.Focused;
    input.GotFocus += (s,e) => hint.Hide();
    input.LostFocus += (s,e) => hint.Visible=input.TextLength==0;
   } else input.AccessibleName=UiLanguage.Text("번역 미리보기");
   input.BorderStyle = BorderStyle.None;
   input.BackColor = surface.BackColor;
   surface.Controls.Add(input);
   if (input==draft) surface.Controls[0].BringToFront();
   surface.Resize += (s,e) => RoundedUi.Round(surface,12);
   return surface;
  }
  Button[] filterButtons;
  async Task SelectFilter(int index) {
   filterIndex = index;
   for (int i=0;i<railButtons.Length;i++) RoundedUi.SetSelected(railButtons[i],i==(index==3 ? 1 : index==2 ? 2 : 0));
   for (int i=0;i<filterButtons.Length;i++) RoundedUi.SetSelected(filterButtons[i],i==index);
   Populate(roomSearch.Text);
   if (connected && index != 1) await RefreshDirectoryIfDue();
  }
  Control BuildFilters() {
   var bar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
   var names = new[] { UiLanguage.Text("전체"), UiLanguage.Text("대화") };
   filterButtons = new Button[names.Length];
   for (int i = 0; i < names.Length; ++i) {
    int index = i;
    bar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
    var button = new PillButton { Text = names[i], AccessibleName = names[i], Dock = DockStyle.Fill };
    RoundedUi.ApplyButton(button,i==filterIndex);
    button.Margin = new Padding(2,3,2,4);
    button.Padding = Padding.Empty;
    button.Click += async (s,e) => await SelectFilter(index);
    filterButtons[i]=button;
    bar.Controls.Add(button, i, 0);
   }
   return bar;
  }
  Control BuildHeader() {
   var bar = new TableLayoutPanel { Dock=DockStyle.Fill, ColumnCount=5, RowCount=1, Margin=Padding.Empty, Padding=new Padding(10,5,7,5), BackColor=Color.White };
   bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,48));
   bar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
   for (int i = 0; i < 3; ++i) bar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
   var avatar = new Panel { Width=46, Height=46, Anchor=AnchorStyles.Left, Margin=Padding.Empty };
   headerAvatar = avatar;
   avatar.Paint += (s,e) => { if (room != null) DrawAvatar(e.Graphics,avatar.ClientRectangle,room,title.Text); };
   title.Font = new Font(Font.FontFamily,13,FontStyle.Bold);
   title.TextChanged += (s,e) => avatar.Invalidate();
   bar.Controls.Add(avatar,0,0);
   var search = new Button { Text="\uE721", Font=railIconFont, AccessibleName=UiLanguage.Text("대화 기록 검색"), Width=38, Height=38, Anchor=AnchorStyles.None };
   RoundedUi.ApplyButton(search);
   search.Click += async (s,e) => await Run(SearchHistory);
   bar.Controls.Add(title, 1, 0);
   bar.Controls.Add(login, 2, 0);
   login.EnabledChanged += (s,e) => login.Visible=login.Enabled;
   login.Visible=login.Enabled;
   bar.Controls.Add(search, 3, 0);
   var info = new Button { Text="…", AccessibleName=UiLanguage.Text("대화 정보"), Width=38, Height=38, Anchor=AnchorStyles.None };
   RoundedUi.ApplyButton(info);
   info.Click += async (s,e) => await Run(ChatInfo);
   bar.Controls.Add(info, 4, 0);
   bar.Paint += (s,e) => e.Graphics.DrawLine(Pens.Gainsboro,0,bar.Height-1,bar.Width,bar.Height-1);
   return bar;
  }
  Control BuildTranslationBar() {
   var bar = new FlowLayoutPanel { Dock=DockStyle.Fill, FlowDirection=FlowDirection.RightToLeft, WrapContents=false, Margin=new Padding(8,3,10,0) };
   var auto = new CheckBox { Text=TranslationToggleText(), AccessibleName=UiLanguage.Text("자동 번역"), Checked=automatic,
    Appearance=Appearance.Button, FlatStyle=FlatStyle.Flat, TextAlign=ContentAlignment.MiddleCenter,
    BackColor=Color.White, ForeColor=Color.DarkGreen, Size=new Size(192,42), Font=new Font(Font.FontFamily,11,FontStyle.Bold) };
   auto.FlatAppearance.BorderSize=0;
   auto.FlatAppearance.CheckedBackColor=Color.White;
   auto.Resize += (s,e) => RoundedUi.Round(auto,21);
   RoundedUi.Round(auto,21);
   auto.CheckedChanged += (s,e) => {
    automatic = auto.Checked;
    auto.Text=TranslationToggleText();
    try { SavePreferences(); }
    catch (Exception error) { status.Text=error.Message; }
    if (automatic && room != null && translator.Key != "") TranslateInBackground(room);
   };
   autoToggle = auto;
   bar.Controls.Add(auto);
   historyButton = new Button { Text = UiLanguage.Text("이전 메시지"), AutoSize = true, Enabled = false, Height = 36 };
   historyButton.Click += async (sender,args) => await Run(LoadOlderMessages);
   bar.Controls.Add(historyButton);
   messages.Scroll += (sender,args) => {
    if (!rebuildingMessages && args.ScrollOrientation == ScrollOrientation.VerticalScroll)
     viewingOlder = args.NewValue + messages.ClientSize.Height < messages.AutoScrollMinSize.Height - 24;
   };
   return bar;
  }
  string TranslationToggleText() { return UiLanguage.Text("文ᴬ   자동번역 ") + (automatic ? "ON" : "OFF"); }
  CheckBox autoToggle;
  async Task ChatInfo() {
   if (!connected || room == null) throw new InvalidOperationException(UiLanguage.Text("대화방을 선택하세요."));
   var id = room;
   if (id.EndsWith("@chatroom", StringComparison.Ordinal)) {
    var members = await engine.Pages(AccountPath + "/groups/" + Engine.Part(id) + "/members", Cancel);
    if (!closing && room == id) ShowGroupMemberList(id, members);
   } else {
    var result = await engine.Json(AccountPath + "/contacts/lookup", Cancel, new { ids = new[] { id } });
    var contact = Engine.Items(result).SingleOrDefault(x => Engine.Get(x, "id") == id);
    if (contact == null) throw new InvalidOperationException(UiLanguage.Text("위챗에서 연락처 이름을 확인하지 못했습니다."));
    var name = DisplayName(contact);
    foreach (var entry in inventory.Concat(directory).Where(x => x.Id == id)) entry.Name = name;
    title.Text = name;
    listing = true;
    try { rooms.Refresh(); } finally { listing = false; }
   }
  }
  void ShowGroupMemberList(string group, List<IDictionary<string, object>> members) {
   var names = members.Select(DisplayName).ToArray();
   using (var nameFont = new Font(Font.FontFamily, 14))
   using (var headingFont = new Font(Font.FontFamily, 15, FontStyle.Bold))
   using (var dialog = new Form {
    Text = UiLanguage.Text("그룹 멤버"), StartPosition = FormStartPosition.CenterParent,
    ClientSize = new Size(460, 480), MinimumSize = new Size(360, 300),
    ShowInTaskbar = false, AutoScaleMode = AutoScaleMode.Dpi, BackColor = Color.White
   }) {
    var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), ColumnCount = 1, RowCount = 3 };
    layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
    layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
    layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
    var caption = new Label { Text = UiLanguage.Text("그룹 멤버 ") + names.Length + UiLanguage.Text("명"), Font = headingFont,
     AutoSize = true, Margin = new Padding(3, 3, 3, 12) };
    layout.Controls.Add(caption, 0, 0);
    var list = new ListBox { Dock = DockStyle.Fill, Font = nameFont, DrawMode = DrawMode.OwnerDrawFixed,
     BorderStyle = BorderStyle.None, IntegralHeight = false, AccessibleName = UiLanguage.Text("그룹 멤버 목록") };
    list.Items.AddRange(names);
    list.DrawItem += (sender, args) => {
     if (args.Index < 0 || args.Index >= names.Length) return;
     args.DrawBackground();
     var bounds = args.Bounds;
     var icon = Math.Min(bounds.Height - 10, 38);
     DrawAvatar(args.Graphics, new Rectangle(bounds.Left + 8, bounds.Top + (bounds.Height - icon) / 2, icon, icon),
      Engine.Get(members[args.Index], "id"), names[args.Index]);
     var left = bounds.Left + icon + 20;
     TextRenderer.DrawText(args.Graphics, names[args.Index], nameFont,
      Rectangle.FromLTRB(left, bounds.Top, bounds.Right - 8, bounds.Bottom), args.ForeColor,
      TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
     args.DrawFocusRectangle();
    };
    Control content = list;
    if (names.Length == 0) {
     list.Dispose();
     content = new Label { Dock = DockStyle.Fill, Font = nameFont, Text = UiLanguage.Text("저장된 그룹 멤버가 없습니다.") };
    } else {
     dialog.Shown += async (sender, args) => {
      list.ItemHeight = Math.Max(48, list.Font.Height + 22);
      foreach (var member in members.Take(12)) {
       if (dialog.IsDisposed || closing) break;
       await LoadAvatar(Engine.Get(member, "id"), group, refresh: false);
       if (!list.IsDisposed) list.Invalidate();
      }
     };
    }
    layout.Controls.Add(content, 0, 1);
    var done = new Button { Text = UiLanguage.Text("닫기"), AutoSize = true, DialogResult = DialogResult.Cancel, Anchor = AnchorStyles.Right };
    layout.Controls.Add(done, 0, 2);
    dialog.Controls.Add(layout);
    dialog.CancelButton = done;
    dialog.ShowDialog(this);
   }
  }
  static string DisplayName(IDictionary<string,object> row) {
   return new[] {"remark","displayName","nickname","name","id"}.Select(key => Engine.Get(row,key))
    .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? "";
  }
  IEnumerable<Room> FilteredRooms() {
   var groups = directory.Where(IsGroup);
   var contacts = directory.Where(x => !IsGroup(x) && x.Id != "filehelper");
   if (filterIndex == 2) return groups;
   if (filterIndex == 3) return contacts;
   IEnumerable<Room> list = inventory;
   if (connected && !inventory.Any(x => x.Id == "filehelper"))
    list = list.Concat(new[] { new Room { Id = "filehelper", Name = UiLanguage.Text("파일 전송"), Version = "", Unread = "" } });
   if (filterIndex != 0) return list;
   var seen = new HashSet<string>(list.Select(x => x.Id));
   var extra = groups.Concat(contacts).Where(x => seen.Add(x.Id)).ToArray();
   return list.Concat(extra.OrderBy(x => IsGroup(x) && !IsGroupName(x.Name,x.Id) && !groupNames.ContainsKey(x.Id)));
  }
  static bool IsGroup(Room entry) { return entry.Id.EndsWith("@chatroom", StringComparison.Ordinal); }
  async Task ReadDirectory() {
   var contactsRequest = engine.Pages(AccountPath + "/contacts", Cancel);
   var groupsRequest = engine.Pages(AccountPath + "/groups", Cancel);
   await Task.WhenAll(contactsRequest, groupsRequest);
   var contacts = await contactsRequest;
   var groups = await groupsRequest;
   foreach (var contact in contacts) {
    var id = Engine.Get(contact,"id");
    if (id == "" || id.EndsWith("@chatroom",StringComparison.Ordinal)) continue;
    var english = new[]{"remark","nickname","displayName"}.Select(k => Engine.Get(contact,k).Trim())
     .FirstOrDefault(n => n != id && System.Text.RegularExpressions.Regex.IsMatch(n,@"\A[\p{IsBasicLatin}\p{IsLatin-1Supplement}\p{IsLatinExtended-A}]+\z") &&
      System.Text.RegularExpressions.Regex.IsMatch(n,"[A-Za-z]"));
    if (english != null) englishNames[id] = english;
   }
   directory.Clear();
   var seen = new HashSet<string>();
   foreach (var item in groups.Concat(contacts)) {
    var id = Engine.Get(item, "id");
    if (id == "" || !seen.Add(id)) continue;
    var name = id.EndsWith("@chatroom",StringComparison.Ordinal) ? ReadGroupName(item,id) :
     new[] { "remark", "displayName", "nickname", "name" }.Select(k => Engine.Get(item,k))
     .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x) && x != id);
    var entry = new Room { Id = id, Name = name ?? id, Version = "", Unread = "" };
    directory.Add(entry);
    if (IsGroup(entry) && name != null) groupNames[id] = name;
   }
   var ordered = directory.OrderBy(x => x.Name == x.Id)
    .ThenBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
   directory.Clear();
   directory.AddRange(ordered);
   if (!closing) Populate(roomSearch.Text);
  }
  async Task RefreshDirectoryIfDue() {
   if (busy || loading || readingDirectory || closing || DateTime.UtcNow < nextDirectory) return;
   readingDirectory = true;
   nextDirectory = DateTime.UtcNow.AddSeconds(45);
   try { await ReadDirectory(); }
   catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing && !busy) status.Text = UiLanguage.Text("그룹·연락처 목록: ") + error.Message; }
   finally { readingDirectory = false; }
  }
  Task SearchHistory() { return SearchMessages(false, ""); }
  Task SearchMessages(bool global, string initial) {
   if (!connected || (!global && room == null)) throw new InvalidOperationException(UiLanguage.Text("검색할 대화방을 선택하세요."));
   using (var dialog = new Form { Text = global ? UiLanguage.Text("전체 대화 검색") : UiLanguage.Text("대화 기록 검색"), Width = 620, Height = 420, StartPosition = FormStartPosition.CenterParent }) {
    var query = new TextBox { Dock = DockStyle.Top, Text = initial };
    var results = new RichTextBox { Dock = DockStyle.Fill, ReadOnly = true, DetectUrls = false };
    var go = new Button { Text = UiLanguage.Text("검색"), Dock = DockStyle.Bottom };
    var id = room;
    go.Click += async (s,e) => {
     if (string.IsNullOrWhiteSpace(query.Text)) return;
     go.Enabled = false;
     try {
      var path = global ? AccountPath + "/messages" : RoomPath(id) + "/messages";
      var page = await engine.Pages(path + "?search=" + Engine.Part(query.Text.Trim()), Cancel);
      var hits = page.Select(item => {
       var peer = Engine.Get(item,"threadId");
       var entry = inventory.Concat(directory).FirstOrDefault(candidate => candidate.Id == peer);
       return (global ? (entry == null ? peer : RoomName(entry)) + "\n" : "") + Body(item);
      });
      var names = global ? inventory.Concat(directory).GroupBy(entry => entry.Id).Select(group => group.First())
       .Where(entry => RoomName(entry).IndexOf(query.Text.Trim(),StringComparison.CurrentCultureIgnoreCase) >= 0)
       .Select(RoomName) : Enumerable.Empty<string>();
      if (!dialog.IsDisposed) {
       var text = string.Join("\n\n", names.Concat(hits));
       results.Text = text.Length > 0 ? text : UiLanguage.Text("검색 결과가 없습니다.");
      }
     } catch (Exception error) { if (!dialog.IsDisposed) results.Text = error.Message; }
     finally { if (!dialog.IsDisposed) go.Enabled = true; }
    };
    dialog.Controls.Add(results); dialog.Controls.Add(query); dialog.Controls.Add(go);
    dialog.AcceptButton = go;
    if (initial.Length > 0) dialog.Shown += (s,e) => go.PerformClick();
    dialog.ShowDialog(this);
   }
   return Task.FromResult(0);
  }
  readonly HashSet<string> hiddenMessages = new HashSet<string>();
  IDictionary<string,object> quotedMessage;
  string quotedRoom, lastHidden;
  static bool CanQuote(IDictionary<string,object> row) {
   ulong serverId;
   return row != null && Engine.Object(row,"recall") == null &&
    ulong.TryParse(Engine.Get(row,"serverId"), out serverId) && serverId > 0 &&
    (new[] { "1","3","34","42","43","47","48" }.Contains(Engine.Get(row,"type")) ||
     (Engine.Get(row,"type") == "49" && new[] {"1","3","4","5","6","8","19","51","57","87"}.Contains(Engine.Get(row,"appMessageType"))));
  }
  void BuildMessageMenu() {
   var menu = new ContextMenuStrip();
   IDictionary<string,object> selected = null;
   var copy = menu.Items.Add(UiLanguage.Text("원문 복사"), null, (s,e) => { var value = Body(selected); if (value != "") Clipboard.SetText(value); });
   var save = menu.Items.Add(UiLanguage.Text("첨부 저장"), null, async (s,e) => await Run(SaveAttachment));
   var quote = menu.Items.Add(UiLanguage.Text("인용 답장"), null, (s,e) => {
    quotedMessage = selected; quotedRoom = room; status.Text = UiLanguage.Text("인용 답장 작성 중"); draft.Focus();
   });
   var cancel = menu.Items.Add(UiLanguage.Text("인용 취소"), null, (s,e) => { quotedMessage = null; status.Text = UiLanguage.Text("인용 취소"); });
   var hide = menu.Items.Add(UiLanguage.Text("이 앱에서 숨기기"), null, (s,e) => {
    lastHidden = Engine.Get(selected, "id"); hiddenMessages.Add(lastHidden); Render();
   });
   var undo = menu.Items.Add(UiLanguage.Text("최근 숨김 취소"), null, (s,e) => {
    hiddenMessages.Remove(lastHidden); lastHidden = null; Render();
   });
   var recall = menu.Items.Add(UiLanguage.Text("메시지 회수"), null, async (s,e) => await Run(() => Recall(selected)));
   menu.Opening += (s,e) => {
    var id = menu.SourceControl == null ? null : menu.SourceControl.Tag as string;
    selected = id == null ? null : shown.FirstOrDefault(x => Engine.Get(x,"id") == id);
    copy.Enabled = hide.Enabled = selected != null;
    save.Enabled = connected && !busy && shown.Any(row => AttachmentLabel(row) != "");
    quote.Enabled = CanQuote(selected);
    recall.Enabled = CanQuote(selected) && Engine.Get(selected,"direction") == "outgoing";
    cancel.Enabled = quotedMessage != null && quotedRoom == room;
    undo.Enabled = lastHidden != null;
   };
   messages.ContextMenuStrip = menu;
  }
  async Task Recall(IDictionary<string,object> message) {
   if (!connected || !CanQuote(message) || Engine.Get(message,"direction") != "outgoing") return;
   if (MessageBox.Show(this,UiLanguage.Text("선택한 메시지를 위챗에서 회수할까요?"), UiLanguage.Text("메시지 회수"), MessageBoxButtons.YesNo) != DialogResult.Yes) return;
   var id = Engine.Get(message,"id");
   var op = await engine.Json(AccountPath + "/messages/" + Engine.Part(id) + "/recall", Cancel,
    new { serverId = Engine.Get(message,"serverId") }, Guid.NewGuid().ToString("N"));
   var opId = Engine.Get(op,"id");
   for (int i = 0; i < 20 && opId != "" && new[] {"queued","running"}.Contains(Engine.Get(op,"state")); ++i) {
    await Task.Delay(600, Cancel);
    op = await engine.Json(AccountPath + "/operations/" + Engine.Part(opId), Cancel);
   }
   status.Text = Engine.Get(op,"state") == "succeeded" ? UiLanguage.Text("위챗이 회수 요청을 수락했습니다.") : UiLanguage.Text("회수 상태: ") + Engine.Get(op,"state");
  }
 }
}
