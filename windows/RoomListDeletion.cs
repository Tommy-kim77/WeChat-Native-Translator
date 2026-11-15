using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  HashSet<string> removedRooms = new HashSet<string>(StringComparer.Ordinal);
  Action loadRemovedRooms;

  void BindRoomListDeletion(string directory) {
   string owner = null;
   string path = null;
   Room target = null;
   var menu = new ContextMenuStrip();
   var delete = menu.Items.Add(UiLanguage.Text("번역기 목록에서 삭제"));
   var restore = menu.Items.Add(UiLanguage.Text("목록에서 삭제한 방 모두 복원"));
   rooms.MouseUp += (sender, args) => {
    if (args.Button != MouseButtons.Right || busy || !connected || path == null) return;
    int index = rooms.IndexFromPoint(args.Location);
    target = index == ListBox.NoMatches ? null : (Room)rooms.Items[index];
    delete.Enabled = target != null;
    restore.Enabled = removedRooms.Count > 0;
    menu.Show(rooms, args.Location);
   };
   loadRemovedRooms = () => {
    if (owner == translationOwner) return;
    path = null;
    var loaded = new HashSet<string>(StringComparer.Ordinal);
    try {
     if (!string.IsNullOrEmpty(translationOwner)) {
      using (var hash = SHA256.Create()) {
       var file = Convert.ToBase64String(hash.ComputeHash(Encoding.UTF8.GetBytes(translationOwner)))
        .Replace('/', '_').Replace('+', '-').TrimEnd('=');
       path = Path.Combine(directory, "removed-rooms-" + file + ".txt");
      }
      if (File.Exists(path)) loaded.UnionWith(File.ReadAllLines(path).Select(Uri.UnescapeDataString));
     }
    } catch (IOException) { path = null; status.Text = UiLanguage.Text("삭제한 방 목록을 읽을 수 없습니다."); }
    catch (UnauthorizedAccessException) { path = null; status.Text = UiLanguage.Text("삭제한 방 목록을 읽을 수 없습니다."); }
    removedRooms = loaded;
    owner = translationOwner;
   };
   delete.Click += (sender, args) => {
    if (target == null || busy || path == null || owner != translationOwner) return;
    var id = target.Id;
    var updated = new HashSet<string>(removedRooms, StringComparer.Ordinal) { id };
    if (!SaveRemovedRooms(path, updated)) return;
    if (room == id) {
     drafts[id] = draft.Text;
     room = null;
     title.Text = UiLanguage.Text("대화방을 선택하세요");
     headerAvatar.Invalidate();
     draft.Clear();
     ClearPreview();
     shown.Clear();
     rendered = null;
     ClearMessageCards();
    }
    Populate(roomSearch.Text);
    status.Text = UiLanguage.Text("번역기 목록에서 삭제했습니다. 대화 기록은 보관됩니다.");
   };
   restore.Click += (sender, args) => {
    if (!busy && path != null && owner == translationOwner &&
        SaveRemovedRooms(path, new HashSet<string>(StringComparer.Ordinal))) Populate(roomSearch.Text);
   };
   rooms.Disposed += (sender, args) => menu.Dispose();
  }

  bool SaveRemovedRooms(string path, HashSet<string> updated) {
   var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
   try {
    File.WriteAllLines(temp, updated.Select(Uri.EscapeDataString));
    if (File.Exists(path)) File.Replace(temp, path, null);
    else File.Move(temp, path);
    removedRooms = updated;
    return true;
   } catch (IOException) { status.Text = UiLanguage.Text("삭제한 방 목록을 저장할 수 없습니다."); }
   catch (UnauthorizedAccessException) { status.Text = UiLanguage.Text("삭제한 방 목록을 저장할 수 없습니다."); }
   finally {
    try { File.Delete(temp); } catch (IOException) {} catch (UnauthorizedAccessException) {}
   }
   return false;
  }
 }
}
