using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  readonly Dictionary<string,Bitmap> avatars = new Dictionary<string,Bitmap>();
  readonly Dictionary<string,DateTime> avatarAttempts = new Dictionary<string,DateTime>();
  readonly Dictionary<string,List<string>> groupFaces = new Dictionary<string,List<string>>();
  readonly Dictionary<string,string> senderNames = new Dictionary<string,string>();
  bool loadingAvatars;
  string ownAvatarId = "";
  async void LoadAvatarsInBackground(string selected) { await LoadVisibleAvatars(selected); }
  string SenderName(IDictionary<string,object> item, string id) {
   var value = Engine.Get(item,"senderName");
   if (value != "" && value != id) return value;
   if (room != null && senderNames.TryGetValue(room + "|" + id, out value)) return value;
   var contact = directory.FirstOrDefault(x => x.Id == id && x.Name != id);
   return contact == null ? UiLanguage.Text("이름 확인 중") : contact.Name;
  }
  void DrawRoom(object sender, DrawItemEventArgs e) {
   if (e.Index < 0 || e.Index >= rooms.Items.Count) return;
   var item = (Room)rooms.Items[e.Index];
   var selected = (e.State & DrawItemState.Selected) != 0;
   using (var paint = new SolidBrush(rooms.BackColor)) e.Graphics.FillRectangle(paint,e.Bounds);
   if (selected) {
    var card = Rectangle.Inflate(e.Bounds,-3,-3);
    using (var shape = RoundedUi.RoundedRectangle(card,13))
    using (var background = new SolidBrush(Color.FromArgb(220,246,229)))
     e.Graphics.FillPath(background,shape);
   }
   var icon = new Rectangle(e.Bounds.Left + 13, e.Bounds.Top + (e.Bounds.Height - 48)/2, 48, 48);
   DrawAvatar(e.Graphics, icon, item.Id, item.Name);
   bool hasPreview = !string.IsNullOrEmpty(item.Preview);
   int start = icon.Right+10;
   int lineWidth = Math.Max(0,e.Bounds.Right-start-50);
   var text = new Rectangle(start,e.Bounds.Top+(hasPreview ? 17 : 0),lineWidth,hasPreview ? 22 : e.Bounds.Height);
   TextRenderer.DrawText(e.Graphics,item.Name,rooms.Font,text,Color.FromArgb(31,31,31),
    TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
   if (hasPreview) TextRenderer.DrawText(e.Graphics,item.Preview,rooms.Font,new Rectangle(start,e.Bounds.Top+41,lineWidth,20),Color.DimGray,
    TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
   if (!string.IsNullOrEmpty(item.Time)) TextRenderer.DrawText(e.Graphics,item.Time,rooms.Font,
    new Rectangle(e.Bounds.Right-48,e.Bounds.Top+18,46,20),Color.DimGray,TextFormatFlags.Right | TextFormatFlags.NoPrefix);
   int unread;
   if (int.TryParse(item.Unread, out unread) && unread > 0) {
    var badge = new Rectangle(e.Bounds.Right - 28,e.Bounds.Top + 43,21,21);
    using (var green = new SolidBrush(Color.FromArgb(16,142,66))) e.Graphics.FillEllipse(green,badge);
    TextRenderer.DrawText(e.Graphics,unread > 99 ? "99+" : unread.ToString(),rooms.Font,badge,Color.White,
     TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
   }
   e.DrawFocusRectangle();
  }
  void DrawAvatar(Graphics g, Rectangle bounds, string id, string title) {
   var state = g.Save();
   try {
    using (var circle = new System.Drawing.Drawing2D.GraphicsPath()) {
     circle.AddEllipse(bounds);
     g.SetClip(circle,System.Drawing.Drawing2D.CombineMode.Intersect);
     DrawAvatarContent(g,bounds,id,title);
    }
   } finally { g.Restore(state); }
  }
  void DrawAvatarContent(Graphics g, Rectangle bounds, string id, string title) {
   Bitmap bitmap;
   if (avatars.TryGetValue(id, out bitmap)) { g.DrawImage(bitmap,bounds); return; }
   List<string> members;
   if (groupFaces.TryGetValue(id,out members) && members.Any(avatars.ContainsKey)) {
    var faces = members.Where(avatars.ContainsKey).Take(9).ToArray();
    var columns = faces.Length <= 4 ? 2 : 3;
    var size = bounds.Width / columns;
    using (var background = new SolidBrush(Color.Gainsboro)) g.FillRectangle(background,bounds);
    for (int i=0;i<faces.Length;i++) g.DrawImage(avatars[faces[i]],bounds.X + i%columns*size,bounds.Y + i/columns*size,size,size);
    return;
   }
   using (var background = new SolidBrush(Color.FromArgb(7,172,103))) g.FillRectangle(background,bounds);
   var mark = id.EndsWith("@chatroom",StringComparison.Ordinal) ? "群" : id == "filehelper" ? "↗" :
    string.IsNullOrWhiteSpace(title) ? "?" : StringInfoFirst(title);
   TextRenderer.DrawText(g,mark,rooms.Font,bounds,Color.White,TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
  }
  static string StringInfoFirst(string value) { return System.Globalization.StringInfo.GetNextTextElement(value); }
  async Task LoadAvatar(string id, string group = null, bool refresh = true) {
   if (id == "" || id == "filehelper" || avatars.ContainsKey(id) || avatars.Count >= 250) return;
   DateTime retry;
   if (avatarAttempts.TryGetValue(id,out retry) && retry > DateTime.UtcNow) return;
   avatarAttempts[id] = DateTime.UtcNow.AddSeconds(20);
   try {
    using (var timeout = System.Threading.CancellationTokenSource.CreateLinkedTokenSource(Cancel)) {
     timeout.CancelAfter(8000);
     var path = AccountPath + "/avatars/" + Engine.Part(id);
     System.Net.Http.HttpResponseMessage result = null;
     try { result = await engine.Request(path,timeout.Token); }
     catch (System.Net.Http.HttpRequestException error) {
      if (!error.Message.Contains("(404)")) return;
     }
     if (result == null) {
      if (!refresh) return;
      object body = group == null ? (object)new { } : new { roomId = group };
      await AwaitMetadata(await engine.Json(path + "/refresh",Cancel,body));
      result = await engine.Request(path,Cancel);
     }
     using (result) {
     await result.Content.LoadIntoBufferAsync(4 * 1024 * 1024);
     using (var stream = new MemoryStream(await result.Content.ReadAsByteArrayAsync()))
     using (var image = Image.FromStream(stream)) {
      if (!closing && image.Width <= 2048 && image.Height <= 2048) avatars[id] = new Bitmap(image,48,48);
     }
    }
    }
   } catch (Exception) {}
  }
  async Task AwaitMetadata(IDictionary<string,object> operation) {
   var id = Engine.Get(operation,"id");
   if (id == "") throw new IOException(UiLanguage.Text("정보 갱신 작업 ID가 없습니다."));
   for (int i=0;i<20;i++) {
    var state = Engine.Get(operation,"state");
    if (state == "succeeded") return;
    if (new[] {"failed","cancelled","rejected","needs_login"}.Contains(state)) break;
    await Task.Delay(750,Cancel);
    operation = await engine.Json(AccountPath + "/operations/" + Engine.Part(id),Cancel);
   }
   throw new IOException(UiLanguage.Text("위챗 정보 갱신을 확인하지 못했습니다."));
  }
  readonly Dictionary<string,DateTime> rosterAttempts = new Dictionary<string,DateTime>();
  async Task LoadRoster(string group, bool refresh) {
   DateTime retry;
   if (rosterAttempts.TryGetValue(group,out retry) && retry > DateTime.UtcNow) return;
   rosterAttempts[group] = DateTime.UtcNow.AddMinutes(2);
   var path = AccountPath + "/groups/" + Engine.Part(group) + "/members";
   var members = await engine.Pages(path,Cancel);
   if (members.Count == 0 && refresh) {
    await AwaitMetadata(await engine.Json(path + "/refresh",Cancel,new { }));
    members = await engine.Pages(path,Cancel);
   }
   if (members.Count > 0) groupFaces[group] = members.Select(x => Engine.Get(x,"id")).Where(x => x != "").Distinct().Take(9).ToList();
   foreach (var member in members) {
    var id = Engine.Get(member,"id");
    var name = new[]{"displayName","roomDisplayName","mentionName"}.Select(k => Engine.Get(member,k).Trim()).FirstOrDefault(x => x != "" && x != id);
    if (id != "" && name != null) senderNames[group + "|" + id] = name;
   }
  }
  async Task LoadVisibleAvatars(string selected) {
   if (loadingAvatars || closing) return;
   loadingAvatars = true;
   try {
    if (selected != null && !groupFaces.ContainsKey(selected) && !selected.EndsWith("@chatroom",StringComparison.Ordinal))
     await LoadAvatar(selected);
    if (ownAvatarId == "") ownAvatarId = Engine.Get(await engine.Json(AccountPath,Cancel),"ownUsername");
    if (ownAvatarId != "") await LoadAvatar(ownAvatarId);
    var visible = rooms.Items.Cast<Room>().Skip(Math.Max(0,rooms.TopIndex)).Take(8).ToArray();
    bool groupSelected = selected != null && selected.EndsWith("@chatroom",StringComparison.Ordinal);
    var incomingSenders = groupSelected
     ? shown.Where(ShowGroupSender).Select(x => Engine.Get(x,"senderId")).Where(x => x != "").Distinct().Take(12).ToArray()
     : new string[0];
    if (groupSelected) {
     await LoadAvatar(selected,refresh:false);
     try { await LoadRoster(selected,true); } catch (Exception) {}
     if (!closing && room == selected) Render();
     foreach (var id in incomingSenders) { if (closing || busy) return; await LoadAvatar(id,selected); }
    }
    foreach (var item in visible) {
     if (closing || busy) return;
     if (item.Id.EndsWith("@chatroom",StringComparison.Ordinal)) {
      await LoadAvatar(item.Id,refresh:false);
      if (!groupFaces.ContainsKey(item.Id)) {
       try { await LoadRoster(item.Id,true); } catch (Exception) {}
      }
      List<string> members;
      if (groupFaces.TryGetValue(item.Id,out members))
       foreach (var id in members) { if (closing || busy) return; await LoadAvatar(id,item.Id); }
     } else await LoadAvatar(item.Id);
     if (!closing) rooms.Invalidate();
    }
   } catch (Exception) {}
   finally {
    loadingAvatars = false;
    if (!closing) { rooms.Invalidate(); headerAvatar.Invalidate(); profileAvatar.Invalidate(); if (room == selected && selected != null) Render(); }
   }
  }
  static bool ShowGroupSender(IDictionary<string,object> row) {
   int type;
   return Engine.Get(row,"direction") != "outgoing" && Engine.Object(row,"recall") == null &&
    int.TryParse(Engine.Get(row,"type"),out type) && type < 10000 &&
    (Engine.Get(row,"direction") == "incoming" || Engine.Get(row,"senderId") != "");
  }
 }
}
