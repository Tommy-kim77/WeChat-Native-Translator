using System;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  bool rebuildingMessages;
  sealed class MessageViewport {
   public string Room, Anchor;
   public int Top, Offset;
   public bool Follow;
  }
  MessageViewport CaptureMessageViewport() {
   var anchor = messages.Controls.Cast<Control>().Where(c => c.Tag is string && c.Bottom > 0)
    .OrderBy(c => c.Top).FirstOrDefault();
   return new MessageViewport { Room=room, Anchor=anchor == null ? null : (string)anchor.Tag,
    Top=anchor == null ? 0 : anchor.Top, Offset=-messages.AutoScrollPosition.Y, Follow=!viewingOlder };
  }
  void RestoreMessageViewport(MessageViewport viewport) {
   if (viewport.Room != room) return;
   if (viewport.Follow) { ScrollToLatest(); return; }
   var anchor = messages.Controls.Cast<Control>().Where(c => c.Tag as string == viewport.Anchor)
    .OrderBy(c => c.Top).FirstOrDefault();
   var offset = anchor == null ? viewport.Offset : -messages.AutoScrollPosition.Y + anchor.Top - viewport.Top;
   messages.AutoScrollPosition = new Point(0, Math.Max(0,offset));
  }
  void FinishLoginAttempt() {
   bool approved = approvedSession;
   if (!connected) approvedSession = false;
   login.Enabled = !connected;
   if (approved && !connected)
    status.Text = UiLanguage.Text("휴대폰 승인 완료 · 계정 또는 대화 목록 확인 실패");
  }
 }
}
