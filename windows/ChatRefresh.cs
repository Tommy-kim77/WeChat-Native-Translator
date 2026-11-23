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
  async Task SyncMessagesIfDue() {
   if (!connected || busy || closing || syncingMessages || DateTime.UtcNow < nextMessageSync) return;
   syncingMessages = true;
   nextMessageSync = DateTime.UtcNow.AddSeconds(15);
   try {
    var operation = await engine.Json(AccountPath + "/sync", Cancel, new { });
    await AwaitMetadata(operation);
    await RefreshChat();
    await RefreshMessages();
   } catch (OperationCanceledException) {}
   catch (Exception error) { if (!closing && !busy) status.Text = error.Message; }
   finally { syncingMessages = false; }
  }
  void ScrollToLatest() {
   if (closing || !messages.IsHandleCreated) return;
   BeginInvoke((Action)(() => {
    if (closing || messages.IsDisposed) return;
    messages.PerformLayout();
    messages.AutoScrollPosition = new Point(0, messages.AutoScrollMinSize.Height);
   }));
  }
 }
}
