using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  string olderCursor = "";
  bool historyExtended, viewingOlder;
  Button historyButton;
  readonly HashSet<string> historyCursors = new HashSet<string>(StringComparer.Ordinal);

  void ResetHistory() {
   olderCursor = "";
   historyExtended = viewingOlder = false;
   historyCursors.Clear();
   UpdateHistoryButton();
  }

  void UpdateHistoryButton() {
   if (historyButton != null) historyButton.Enabled = connected && olderCursor != "";
  }

  static List<IDictionary<string,object>> MergeHistory(
      IEnumerable<IDictionary<string,object>> existing, IEnumerable<IDictionary<string,object>> latest) {
   var updated = latest.ToList();
   var ids = new HashSet<string>(updated.Select(row => Engine.Get(row,"id")),StringComparer.Ordinal);
   return existing.Where(row => !ids.Contains(Engine.Get(row,"id"))).Concat(updated).ToList();
  }

  async Task LoadOlderMessages() {
   if (!connected || room == null || olderCursor == "") return;
   var id = room;
   var cursor = olderCursor;
   if (historyCursors.Contains(cursor)) throw new InvalidOperationException(UiLanguage.Text("대화 목록 페이지 응답이 반복됩니다."));
   historyButton.Enabled = false;
   try {
    var page = await engine.Json(RoomPath(id) + "/messages?limit=80&cursor=" + Engine.Part(cursor),Cancel);
    if (closing || room != id) return;
    var older = Engine.Items(page).Reverse().ToList();
    var next = Engine.Get(page,"nextCursor");
    if (next == cursor || (next != "" && historyCursors.Contains(next)))
     throw new InvalidOperationException(UiLanguage.Text("대화 목록 페이지 응답이 반복됩니다."));
    int height = messages.AutoScrollMinSize.Height;
    int offset = -messages.AutoScrollPosition.Y;
    historyCursors.Add(cursor);
    olderCursor = next;
    historyExtended = viewingOlder = true;
    shown = MergeHistory(older,shown);
    Render();
    messages.PerformLayout();
    messages.AutoScrollPosition = new Point(0, Math.Max(0, offset + messages.AutoScrollMinSize.Height - height));
   } finally { if (!closing) UpdateHistoryButton(); }
  }
 }
}
