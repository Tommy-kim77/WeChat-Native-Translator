using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  sealed class DraftMember {
   public string Id, Name;
   public string Token { get { return "@" + Name + "\u2005"; } }
  }

  readonly Dictionary<string,List<DraftMember>> draftMembers = new Dictionary<string,List<DraftMember>>(StringComparer.Ordinal);

  List<DraftMember> DraftMentions(string group, string text) {
   List<DraftMember> selected;
   if (group == null || !draftMembers.TryGetValue(group, out selected)) return new List<DraftMember>();
   int length = 0, count = 0;
   foreach (var member in selected) {
    if (text.Length - length < member.Token.Length ||
        string.CompareOrdinal(text, length, member.Token, 0, member.Token.Length) != 0) break;
    length += member.Token.Length;
    count++;
   }
   if (count < selected.Count) selected.RemoveRange(count, selected.Count - count);
   if (selected.Count == 0) draftMembers.Remove(group);
   return selected;
  }

  void BindMentions() {
   var menu = new ContextMenuStrip();
   var roster = new Dictionary<string,List<IDictionary<string,object>>>(StringComparer.Ordinal);
   var fetchedAt = new Dictionary<string,DateTime>(StringComparer.Ordinal);
   var loadingRoster = new HashSet<string>(StringComparer.Ordinal);
   menu.KeyPress += (sender,args) => {
    char key = args.KeyChar;
    if (key != '\b' && char.IsControl(key)) return;
    var current = draft.Text;
    args.Handled = true;
    menu.Close();
    draft.Focus();
    draft.Text = key == '\b' ? current.Substring(0, Math.Max(0, current.Length - 1)) : current + key;
    draft.SelectionStart = draft.TextLength;
   };
   draft.Disposed += (sender, args) => menu.Dispose();
   draft.TextChanged += async (sender,args) => {
    menu.Close();
    var group = room;
    var text = draft.Text;
    var selected = DraftMentions(group, text);
    int start = selected.Sum(member => member.Token.Length);
    if (!connected || busy || closing || !draft.Focused || group == null ||
        !group.EndsWith("@chatroom", StringComparison.Ordinal) || text.Length <= start || text[start] != '@') return;
    var query = text.Substring(start + 1);
    if (query.Length > 40 || query.Any(char.IsWhiteSpace) || query.Contains("@")) return;
    try {
     List<IDictionary<string,object>> members;
     DateTime readAt;
     if (!roster.TryGetValue(group, out members) || !fetchedAt.TryGetValue(group, out readAt) ||
         DateTime.UtcNow - readAt > TimeSpan.FromMinutes(2)) {
      if (!loadingRoster.Add(group)) return;
      try {
       var path = AccountPath + "/groups/" + Engine.Part(group) + "/members";
       members = await engine.Pages(path, Cancel);
       if (members.Count == 0 && group == room && !closing) {
        await AwaitMetadata(await engine.Json(path + "/refresh", Cancel, new { }));
        members = await engine.Pages(path, Cancel);
       }
       roster[group] = members;
       fetchedAt[group] = DateTime.UtcNow;
      } finally { loadingRoster.Remove(group); }
     }
     if (closing || busy || room != group || !draft.Focused) return;
     text = draft.Text;
     selected = DraftMentions(group, text);
     start = selected.Sum(member => member.Token.Length);
     if (text.Length <= start || text[start] != '@') return;
     query = text.Substring(start + 1);
     if (query.Length > 40 || query.Any(char.IsWhiteSpace) || query.Contains("@")) return;
     while (menu.Items.Count > 0) menu.Items[0].Dispose();
     var options = members.Select(row => new DraftMember {
      Id = Engine.Get(row,"id"),
      Name = new[] {"mentionName","roomDisplayName","displayName","nickname"}
       .Select(key => Engine.Get(row,key).Trim()).FirstOrDefault(name => name.Length > 0)
     }).Where(member => member.Id != "" && member.Id != "notify@all" &&
      !string.IsNullOrEmpty(member.Name) && !member.Name.Any(char.IsControl) &&
      member.Name.IndexOf(query,StringComparison.CurrentCultureIgnoreCase) >= 0 &&
      !selected.Any(previous => previous.Id == member.Id)).ToArray();
     var duplicates = options.ToLookup(member => member.Name, StringComparer.CurrentCultureIgnoreCase);
     foreach (var member in options.Take(20)) {
      var label = duplicates[member.Name].Count() > 1
       ? member.Name + " (" + member.Id + ")" : member.Name;
      menu.Items.Add(label, null, (s,e) => {
       if (closing || busy || room != group || draft.Text != text) return;
       selected.Add(member);
       draftMembers[group] = selected;
       draft.Text = text.Substring(0,start) + member.Token;
       draft.Focus();
       draft.SelectionStart = draft.TextLength;
      });
     }
     if (menu.Items.Count > 0) menu.Show(draft, new Point(0,0), ToolStripDropDownDirection.AboveRight);
    } catch (OperationCanceledException) {}
    catch (Exception) { if (!closing && room == group) status.Text = UiLanguage.Text("멘션할 그룹 멤버를 불러오지 못했습니다."); }
   };
  }
 }
}
