using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using NativeTranslator;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

sealed class FixtureHandler : HttpMessageHandler {
 public int Sends, Translations;
 public string LastText;
 public bool RejectSends;
 protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation) {
  object response;
  if(request.RequestUri.Host=="fixture.invalid") {
   if(request.Method==HttpMethod.Post && request.RequestUri.AbsolutePath.EndsWith("/sends")) {
    var payload=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(await request.Content.ReadAsStringAsync());
    Sends++; LastText=Convert.ToString(payload["text"]);
    response=new {id="fixture-send-"+Sends,destination=Convert.ToString(payload["threadId"]),state=RejectSends ? "failed" : "accepted"};
   } else response=new {id="personal",authenticated=true,ownUsername="fixture"};
  } else if(request.RequestUri.Host=="api-free.deepl.com") {
   Translations++;
   response=new {translations=new[]{new {text="Fixture translated invoice."}}};
  } else throw new InvalidOperationException("Unexpected network destination in fixture");
  return new HttpResponseMessage(HttpStatusCode.OK) {Content=new StringContent(new JavaScriptSerializer().Serialize(response),Encoding.UTF8,"application/json")};
 }
}


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
 static void PressEnter(TextBox input,Chat chat) {
  chat.Activate(); input.Focus(); Pump();
  Check(input.Focused,"composer receives Enter");
  object message=Message.Create(input.Handle,0x100,(IntPtr)Keys.Enter,IntPtr.Zero);
  var handled=(bool)input.GetType().GetMethod("ProcessCmdKey",Private).Invoke(input,new object[]{message,Keys.Enter});
  Check(handled,"native Enter handler accepts one press");
  var end=DateTime.UtcNow.AddSeconds(4);
  do { Pump(); } while((bool)Get(chat,"busy") && DateTime.UtcNow<end);
  Check(!(bool)Get(chat,"busy"),"submit completes");
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
    // Feed the product's native Enter handler while only fake HTTP handlers are installed.
    var engine=Get(chat,"engine"); ((HttpClient)Get(engine,"http")).Dispose();
    var handler=new FixtureHandler(); Set(engine,"http",new HttpClient(handler)); Set(engine,"address","https://fixture.invalid/v1"); Set(engine,"token","fixture");
    Set(chat,"account","personal"); Set(chat,"connected",true);
    var translator=Get(chat,"translator"); ((HttpClient)Get(translator,"http")).Dispose();
    Set(translator,"http",new HttpClient(handler,false));
    var serializer=new JavaScriptSerializer();
    var cases=serializer.DeserializeObject(File.ReadAllText(args[0])) as object[];
    foreach(var entry in cases) {
     var item=(Dictionary<string,object>)entry; var text=(string)item["text"]; var target=(string)item["target"]; var translate=(bool)item["translate"];
     Check(OutgoingLanguage.RequiresTranslation(text,target)==translate,"language policy: "+target+" / "+text.Replace("\n"," · "));
     if(translate) continue;
     Set(chat,"outgoing",target=="en" ? 1 : target=="ko" ? 0 : 2);
     input.Text=text;
     int count=handler.Sends;
     PressEnter(input,chat);
     Check(handler.Sends==count+1 && handler.LastText==text && input.Text=="" && Get(chat,"prepared")==null,"one Enter sends original without preview or API key");
    }
    Check(handler.Translations==0,"same-language messages make no translation API requests");
    Set(chat,"outgoing",1);
    Set(translator,"<Key>k__BackingField","fixture:fx");
    input.Text="청구서를 보내주세요.";
    int before=handler.Sends;
    PressEnter(input,chat);
    Check(handler.Sends==before && handler.Translations==1 && preview.Text=="Fixture translated invoice.","different language keeps two-step preview");
    preview.Text="Edited fixture translation.";
    PressEnter(input,chat);
    Check(handler.Sends==before+1 && handler.LastText=="Edited fixture translation.","edited translation is sent on next Enter");
    input.Text="Invoice";
    var manual=(Task)chat.GetType().GetMethod("Submit",Private).Invoke(chat,new object[]{true});
    while(!manual.IsCompleted) Pump(); manual.GetAwaiter().GetResult();
    Check(handler.Sends==before+1 && Get(chat,"prepared")!=null,"manual translation button does not unexpectedly send same-language draft");
    preview.Text="Manually edited English preview.";
    PressEnter(input,chat);
    Check(handler.LastText=="Manually edited English preview.","same-language preview edits are respected");
    input.Text="OK"; handler.RejectSends=true;
    PressEnter(input,chat);
    Check(input.Text=="OK","failed direct send keeps original draft");
    handler.RejectSends=false;
    PressEnter(input,chat);
    Check(input.Text=="" && handler.LastText=="OK","direct send can be retried");
    chat.Close();
   }
   return 0;
  } catch(Exception error) { Console.WriteLine(error.ToString()); return 1; }
 }
}
