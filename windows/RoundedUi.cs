using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace NativeTranslator {
 sealed class PillButton : Button {
  protected override void OnPaint(PaintEventArgs e) {
   e.Graphics.Clear(Parent == null ? SystemColors.Control : Parent.BackColor);
   e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
   using (var border = RoundedUi.RoundedRectangle(ClientRectangle, Math.Min(21,Height/2)))
   using (var fill = new SolidBrush(BackColor)) e.Graphics.FillPath(fill,border);
   TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,Enabled ? ForeColor : SystemColors.GrayText,
    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
   if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics,Rectangle.Inflate(ClientRectangle,-5,-5));
  }
 }
 // UI-only styling. Does not change authentication, transport or translation logic.
 static class RoundedUi {
  static readonly Color Green = Color.FromArgb(31, 168, 94);
  static readonly Color PaleGreen = Color.FromArgb(220, 246, 229);
  static readonly Color Surface = Color.FromArgb(244, 247, 249);
  internal static GraphicsPath RoundedRectangle(Rectangle bounds, int radius) {
   var path = new GraphicsPath();
   int d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
   if (d < 2) { path.AddRectangle(bounds); return path; }
   path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
   path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
   path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
   path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
   path.CloseFigure();
   return path;
  }
  internal static void Round(Control control, int radius) {
   if (control.Width < 2 || control.Height < 2) return;
   using (var path = RoundedRectangle(new Rectangle(0, 0, control.Width, control.Height), radius)) {
    var previous = control.Region;
    control.Region = new Region(path);
    if (previous != null) previous.Dispose();
   }
  }
  public static void SetSelected(Button button, bool selected) {
   button.BackColor = selected ? PaleGreen : Surface;
   button.ForeColor = selected ? Color.FromArgb(17, 120, 65) : Color.FromArgb(45, 53, 61);
   button.FlatAppearance.MouseOverBackColor = selected ? PaleGreen : Color.FromArgb(232, 239, 236);
  }
  public static void ApplyButton(Button button, bool primary = false) {
   button.FlatStyle = FlatStyle.Flat;
   button.FlatAppearance.BorderSize = 0;
   button.Cursor = Cursors.Hand;
   button.UseVisualStyleBackColor = false;
   button.Padding = new Padding(7, 2, 7, 2);
   button.Margin = new Padding(3);
   SetSelected(button, primary);
   button.Resize += (sender, args) => Round(button, 12);
   Round(button, 12);
  }
  public static void ApplyPrimary(Button button) {
   ApplyButton(button);
   button.BackColor = Green;
   button.ForeColor = Color.White;
   button.FlatAppearance.MouseOverBackColor = Color.FromArgb(26,144,81);
  }
  public static void ApplySearch(TextBox input) {
   input.BorderStyle = BorderStyle.FixedSingle;
   input.BackColor = Color.White;
   input.ForeColor = Color.FromArgb(45, 53, 61);
   input.Font = new Font("맑은 고딕", 10);
  }
 }
}
