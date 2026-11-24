using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using NativeTranslator;

static class Regression {
 const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
 static object Get(object value,string name) { return value.GetType().GetField(name,Private).GetValue(value); }
 static void Set(object value,string name,object field) { value.GetType().GetField(name,Private).SetValue(value,field); }
 static void Call(object value,string name,params object[] args) { value.GetType().GetMethod(name,Private).Invoke(value,args); }
 static void Pump() { for(int i=0;i<12;i++) { Application.DoEvents(); Thread.Sleep(20); } }
 static void Check(bool value,string name) { if(!value) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); }
 static int Bottom(Panel panel) { return panel.AutoScrollMinSize.Height + panel.AutoScrollPosition.Y - panel.ClientSize.Height; }
 static void Scroll(Panel panel,int y) {
  panel.AutoScrollPosition=new Point(0,Math.Max(0,y));
  typeof(ScrollableControl).GetMethod("OnScroll",Private).Invoke(panel,new object[]{new ScrollEventArgs(ScrollEventType.ThumbPosition,-panel.AutoScrollPosition.Y,ScrollOrientation.VerticalScroll)});
  Pump();
 }
 [STAThread] public static int Main(string[] args) {
  try {
   Application.EnableVisualStyles();
   using(var chat = new Chat(Path.Combine(Path.GetTempPath(),"wechat-regression-fixture"),false,true)) {
    chat.Show(); Pump();
    var input=(TextBox)Get(chat,"draft"); var preview=(TextBox)Get(chat,"preview"); var login=(Button)Get(chat,"login");
    input.Text="Synthetic unsent draft"; preview.Text="Synthetic edited preview";
    Set(chat,"connected",false); Set(chat,"approvedSession",true); login.Enabled=false;
    Call(chat,"FinishLoginAttempt");
    Check(login.Enabled && !(bool)Get(chat,"approvedSession"),"failed approved login allows another QR attempt");
    Check(input.Text=="Synthetic unsent draft" && preview.Text=="Synthetic edited preview","login retry retains draft and preview");
    Set(chat,"connected",true); Set(chat,"approvedSession",true); Call(chat,"FinishLoginAttempt");
    Check(!login.Enabled,"successful login disables redundant QR attempt");
    var rows=(List<IDictionary<string,object>>)Get(chat,"shown"); rows.Clear();
    for(int i=0;i<35;i++) rows.Add(new Dictionary<string,object>{{"id","fixture-"+i},{"type",1},{"direction","incoming"},{"body","Synthetic message "+i+" "+new string('x',170)}});
    Set(chat,"viewingOlder",false); Set(chat,"rendered",null); Call(chat,"Render",true); Pump();
    var panel=(Panel)Get(chat,"messages");
    Check(Bottom(panel)<30,"initial render shows latest message");
    Scroll(panel,Math.Max(100,panel.AutoScrollMinSize.Height/2));
    Check((bool)Get(chat,"viewingOlder"),"manual upward scroll disables automatic following");
    var anchor=panel.Controls.Cast<Control>().Where(c=>c.Tag is string && c.Bottom>0).OrderBy(c=>c.Top).First();
    var id=(string)anchor.Tag; int top=anchor.Top;
    rows[0]["body"]=new string('y',1600); Call(chat,"Render",true); Pump();
    var restored=panel.Controls.Cast<Control>().Where(c=>c.Tag as string==id).OrderBy(c=>c.Top).First();
    Check(Math.Abs(restored.Top-top)<=3 && Bottom(panel)>100,"content expansion keeps visible message and screen position");
    rows.Add(new Dictionary<string,object>{{"id","fixture-new"},{"type",1},{"direction","incoming"},{"body","Synthetic new message"}});
    Call(chat,"Render",true); Pump();
    Check(Bottom(panel)>100,"new message does not interrupt history reading");
    Scroll(panel,panel.AutoScrollMinSize.Height);
    Check(!(bool)Get(chat,"viewingOlder"),"scrolling back to bottom resumes following");
    rows.Last()["body"]=new string('z',2000); Call(chat,"Render",true); Pump();
    Check(Bottom(panel)<30,"latest content expansion remains fully visible");
    chat.Height-=120; Pump();
    Check(Bottom(panel)<30,"window resize keeps latest message visible");
    chat.Close();
   }
   return 0;
  } catch(Exception error) { Console.WriteLine(error.ToString()); return 1; }
 }
}
