using System;
using System.Windows.Forms;
using System.Drawing;
using System.Threading.Tasks;

namespace NativeTranslator {
 sealed class StableRoomList : ListBox {
  public StableRoomList() { DoubleBuffered = true; }
 }
 sealed partial class Chat {
  bool syncingMessages;
  DateTime nextMessageSync;
  async Task<bool> VerifyConnection() {
   if (!connected) return false;
   var profile = await engine.Json(AccountPath, Cancel);
   if (Engine.Get(profile,"authenticated").Equals("true",StringComparison.OrdinalIgnoreCase)) return true;
   connected = false;
   approvedSession = false;
   login.Enabled = true;
   status.Text = UiLanguage.Text("연결이 끊겼습니다. QR 로그인으로 다시 연결하세요. 작성한 메시지는 유지됩니다.");
   return false;
  }
  async Task SyncMessagesIfDue() {
   if (!connected || busy || closing || syncingMessages || DateTime.UtcNow < nextMessageSync) return;
   syncingMessages = true;
   nextMessageSync = DateTime.UtcNow.AddSeconds(15);
   bool failed = false;
   try {
    var operation = await engine.Json(AccountPath + "/sync", Cancel, new { });
    await AwaitMetadata(operation);
    await RefreshChat();
    await RefreshMessages();
   } catch (OperationCanceledException) {}
   catch (Exception) { failed = true; }
   finally { syncingMessages = false; }
   if (failed && !closing && !busy) {
    try {
     if (await VerifyConnection()) status.Text = UiLanguage.Text("메시지 동기화에 실패했습니다. 잠시 후 자동으로 다시 시도합니다.");
    } catch (Exception) {
     if (!closing) status.Text = UiLanguage.Text("메시지 동기화에 실패했습니다. 잠시 후 자동으로 다시 시도합니다.");
    }
   }
  }
  void ScrollToLatest() {
   if (closing || viewingOlder || !messages.IsHandleCreated) return;
   BeginInvoke((Action)(() => {
    if (closing || viewingOlder || messages.IsDisposed) return;
    messages.PerformLayout();
    messages.AutoScrollPosition = new Point(0, messages.AutoScrollMinSize.Height);
   }));
  }
 }
}
