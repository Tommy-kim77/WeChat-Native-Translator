using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed partial class Chat {
  void ClearMessageCards() {
   messages.AutoScrollPosition = Point.Empty;
   while (messages.Controls.Count > 0) messages.Controls[0].Dispose();
   messages.AutoScrollMinSize = Size.Empty;
  }
  static string ChatTime(string value) {
   DateTimeOffset time;
   return DateTimeOffset.TryParse(value,out time) ? time.ToLocalTime().ToString("HH:mm") : "";
  }
  static DateTime? ChatDate(string value) {
   DateTimeOffset time;
   return DateTimeOffset.TryParse(value,out time) ? time.ToLocalTime().Date : (DateTime?)null;
  }
  int AddMessageCard(int y, string id, bool outgoing, string avatar, string sender, string text, string translation, string time) {
   const int edge = 14, iconSize = 42, gap = 9;
   int width = Math.Max(150,messages.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
   int maxText = Math.Max(70,Math.Min(560,(width - 2*(edge+iconSize+gap))*3/4));
   int iconX = outgoing ? width - edge - iconSize : edge;
   int textEdge = outgoing ? iconX-gap : iconX + iconSize + gap;
   var icon = new Panel { Bounds = new Rectangle(iconX,y,iconSize,iconSize) };
   icon.Paint += (s,e) => DrawAvatar(e.Graphics,icon.ClientRectangle,avatar,outgoing ? UiLanguage.Text("나") : sender=="" && avatar==room ? title.Text : sender);
   messages.Controls.Add(icon);
   int top = y;
   if (sender != "") {
    var name = new Label { Text = sender, UseMnemonic = false, ForeColor = Color.DimGray, AutoEllipsis = true,
     Bounds = new Rectangle(textEdge,top,maxText,22), Tag = id, ContextMenuStrip = messages.ContextMenuStrip };
    messages.Controls.Add(name);
    top += 24;
   }
   top += AddBubble(text, translation, time, id, top, textEdge, maxText, outgoing);
   return Math.Max(iconSize,top - y) + 18;
  }
  int AddBubble(string value, string translation, string time, string id, int y, int edge, int maxText, bool outgoing) {
   var flags = TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix;
   bool translated = !string.IsNullOrWhiteSpace(translation) && translation != value;
   int timeWidth = time == "" ? 0 : 46;
   var available = new Size(maxText-timeWidth,10000);
   int textWidth = TextRenderer.MeasureText(value,Font,available,flags).Width + timeWidth;
   if (translated) textWidth = Math.Max(132,Math.Max(textWidth,TextRenderer.MeasureText(translation,Font,new Size(maxText,10000),flags).Width));
   textWidth = Math.Max(timeWidth+20,Math.Min(maxText,textWidth));
   int textHeight = TextRenderer.MeasureText(value,Font,new Size(textWidth-timeWidth,10000),flags).Height;
   int translationHeight = translated ? TextRenderer.MeasureText(translation,Font,new Size(textWidth,10000),flags).Height + 34 : 0;
   int width = textWidth + 28, height = textHeight + 22 + translationHeight;
   var bubble = new BubblePanel(outgoing ? Color.FromArgb(226,246,221) : Color.White) {
    Bounds = new Rectangle(outgoing ? edge-width : edge,y,width,height),
    Tag = id, ContextMenuStrip = messages.ContextMenuStrip
   };
   bubble.Controls.Add(new Label { Text = value, UseMnemonic = false, Bounds = new Rectangle(14,11,textWidth-timeWidth,textHeight),
    BackColor = Color.Transparent, Tag = id, ContextMenuStrip = messages.ContextMenuStrip });
   if (timeWidth > 0) bubble.Controls.Add(new Label { Text=time, ForeColor=Color.DimGray, TextAlign=ContentAlignment.TopRight,
    Bounds=new Rectangle(width-timeWidth-13,11,timeWidth,19),BackColor=Color.Transparent });
   if (translated) {
    bubble.Controls.Add(new Panel { Bounds=new Rectangle(14,textHeight+17,textWidth,1),BackColor=Color.FromArgb(224,231,225) });
    bubble.Controls.Add(new Label { Text=outgoing ? UiLanguage.Text("文ᴬ  번역 미리보기") : "文ᴬ  " + (incoming==0 ? UiLanguage.Text("한국어 ") : "") + UiLanguage.Text("자동번역"), ForeColor=Color.DarkGreen,
     Bounds=new Rectangle(14,textHeight+22,textWidth,21),BackColor=Color.Transparent,Tag=id,ContextMenuStrip=messages.ContextMenuStrip });
    bubble.Controls.Add(new Label { Text=translation,UseMnemonic=false,Bounds=new Rectangle(14,textHeight+45,textWidth,translationHeight-34),
     BackColor=Color.Transparent,Tag=id,ContextMenuStrip=messages.ContextMenuStrip });
   }
   messages.Controls.Add(bubble);
   return height;
  }
  sealed class BubblePanel : Panel {
   readonly Color fill;
   public BubblePanel(Color fill) { this.fill = fill; DoubleBuffered = true; }
   protected override void OnPaint(PaintEventArgs e) {
    base.OnPaint(e);
    e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
    using (var shape = RoundedUi.RoundedRectangle(new Rectangle(0,0,Width-1,Height-1),17))
    using (var brush = new SolidBrush(fill))
    using (var border = new Pen(Color.FromArgb(229,234,230))) {
     e.Graphics.FillPath(brush,shape);
     e.Graphics.DrawPath(border,shape);
    }
   }
  }
 }
}
