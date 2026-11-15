using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace NativeTranslator {
 sealed class Engine : IDisposable {
  public static readonly string Data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WeChat Native Translator Windows");
  readonly string dataDirectory;
  readonly HttpClient http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(125) };
  readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
  Process process;
  string address, token;
  volatile string startupCategory;
  public Engine(string dataDirectory = null) { this.dataDirectory = dataDirectory ?? Data; }
  public static string Part(string s) { return Uri.EscapeDataString(s); }
  public static string Get(IDictionary<string, object> value, string key) {
   object item;
   return value != null && value.TryGetValue(key, out item) ? Convert.ToString(item) : "";
  }
  public static IDictionary<string, object> Object(IDictionary<string, object> value, string key) {
   object item;
   return value != null && value.TryGetValue(key, out item) ? item as IDictionary<string, object> : null;
  }
  public static IEnumerable<IDictionary<string, object>> Items(IDictionary<string, object> value) {
   return ((IEnumerable)value["items"]).Cast<IDictionary<string, object>>();
  }
  public async Task Start(CancellationToken cancel) {
   PrivateDirectory(dataDirectory);
   var binary = Package.EnginePath(dataDirectory);
   var profile = Path.Combine(dataDirectory, "profile");
   PrivateDirectory(profile);
   var tokenFile = Path.Combine(dataDirectory, "local-api-token");
   if (!File.Exists(tokenFile)) File.WriteAllText(tokenFile, Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N"), new UTF8Encoding(false));
   var security = new FileSecurity();
   var sid = WindowsIdentity.GetCurrent().User;
   security.SetAccessRuleProtection(true, false);
   security.SetOwner(sid);
   security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
   if ((File.GetAttributes(tokenFile) & FileAttributes.ReparsePoint) != 0) throw new IOException(UiLanguage.Text("로컬 토큰 파일 경로가 올바르지 않습니다."));
   File.SetAccessControl(tokenFile, security);
   token = File.ReadAllText(tokenFile).Trim();
   if (token.Length < 32) throw new IOException(UiLanguage.Text("로컬 연결 토큰을 읽지 못했습니다."));
   int port;
   var listener = new TcpListener(IPAddress.Loopback, 0);
   listener.Start();
   try { port = ((IPEndPoint)listener.LocalEndpoint).Port; }
   finally { listener.Stop(); }
   var endpoint = "127.0.0.1:" + port;
   address = "http://" + endpoint + "/v1";
   process = StartWithUserOwner(new ProcessStartInfo(binary) {
    Arguments = "--data-dir \"" + profile + "\" --token-file \"" + tokenFile + "\" --listen " + endpoint + " serve",
    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
   });
   process.BeginOutputReadLine();
   process.ErrorDataReceived += (sender, args) => {
    var line = args.Data;
    if (line == null) return;
    if (line.IndexOf("private", StringComparison.OrdinalIgnoreCase) >= 0 || line.IndexOf("ACL", StringComparison.OrdinalIgnoreCase) >= 0)
     startupCategory = UiLanguage.Text("프로필 권한 검사 실패");
    else if (line.IndexOf("lock", StringComparison.OrdinalIgnoreCase) >= 0)
     startupCategory = UiLanguage.Text("프로필 잠금 오류");
    else if (line.IndexOf("sqlite", StringComparison.OrdinalIgnoreCase) >= 0 || line.IndexOf("database", StringComparison.OrdinalIgnoreCase) >= 0)
     startupCategory = UiLanguage.Text("프로필 데이터베이스 오류");
   };
   process.BeginErrorReadLine();
   for (int i = 0; i < 35 && !process.HasExited; ++i) {
    using (var probe = CancellationTokenSource.CreateLinkedTokenSource(cancel)) {
     probe.CancelAfter(500);
     try { await Json("/status", probe.Token); return; }
     catch (HttpRequestException) {}
     catch (OperationCanceledException) { cancel.ThrowIfCancellationRequested(); }
    }
    await Task.Delay(180, cancel);
   }
   if (process.HasExited) process.WaitForExit();
   throw new IOException(UiLanguage.Text("로컬 WeChat 연결 엔진을 시작하지 못했습니다.") +
    (startupCategory == null ? "" : " " + startupCategory));
  }
  [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
  static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
  [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
  static extern bool SetTokenInformation(IntPtr token, int kind, ref IntPtr value, int length);
  [System.Runtime.InteropServices.DllImport("kernel32.dll")]
  static extern bool CloseHandle(IntPtr handle);
  static Process StartWithUserOwner(ProcessStartInfo info) {
   using (var identity = WindowsIdentity.GetCurrent()) {
    if (identity.User.Equals(identity.Owner)) return Process.Start(info);
    // SQLite creates WAL and SHM itself, using the inherited token's default owner.
    var user = new byte[identity.User.BinaryLength];
    var owner = new byte[identity.Owner.BinaryLength];
    identity.User.GetBinaryForm(user, 0);
    identity.Owner.GetBinaryForm(owner, 0);
    IntPtr token;
    if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x88, out token))
     throw new System.ComponentModel.Win32Exception();
    var u = System.Runtime.InteropServices.GCHandle.Alloc(user, System.Runtime.InteropServices.GCHandleType.Pinned);
    var o = System.Runtime.InteropServices.GCHandle.Alloc(owner, System.Runtime.InteropServices.GCHandleType.Pinned);
    try {
     var sid = u.AddrOfPinnedObject();
     if (!SetTokenInformation(token, 4, ref sid, IntPtr.Size))
      throw new System.ComponentModel.Win32Exception();
     try { return Process.Start(info); }
     finally {
      sid = o.AddrOfPinnedObject();
      SetTokenInformation(token, 4, ref sid, IntPtr.Size);
     }
    } finally { u.Free(); o.Free(); CloseHandle(token); }
   }
  }
  internal static void PrivateDirectory(string path) {
   var sid = WindowsIdentity.GetCurrent().User;
   var security = new DirectorySecurity();
   security.SetOwner(sid);
   security.SetAccessRuleProtection(true, false);
   security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
   var folder = Directory.CreateDirectory(path, security);
   if ((folder.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException(UiLanguage.Text("로컬 프로필 경로가 올바르지 않습니다."));
   folder.SetAccessControl(security);
  }
  public async Task<HttpResponseMessage> Request(string path, CancellationToken cancel, HttpMethod method = null, HttpContent body = null, string key = null) {
   using (var req = new HttpRequestMessage(method ?? HttpMethod.Get, address + path)) {
    req.Content = body;
    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
    if (key != null) req.Headers.Add("Idempotency-Key", key);
    var result = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cancel);
    if (result.IsSuccessStatusCode) return result;
    var code = (int)result.StatusCode;
    result.Dispose();
    throw new HttpRequestException(UiLanguage.Text("WeChat 연결 요청 실패 (") + code + ")");
   }
  }
  public async Task<IDictionary<string, object>> Json(string path, CancellationToken cancel, object body = null, string key = null) {
   using (var res = await Request(path, cancel, body == null ? null : HttpMethod.Post,
    body == null ? null : new StringContent(json.Serialize(body), Encoding.UTF8, "application/json"), key)) {
    await res.Content.LoadIntoBufferAsync(16 * 1024 * 1024);
    return json.Deserialize<Dictionary<string, object>>(await res.Content.ReadAsStringAsync());
   }
  }
  public async Task<List<IDictionary<string, object>>> Pages(string path, CancellationToken cancel) {
   var rows = new List<IDictionary<string, object>>();
   var ids = new HashSet<string>();
   var cursors = new HashSet<string>();
   string cursor = "";
   do {
    var page = await Json(path + "?limit=200" + (cursor == "" ? "" : "&cursor=" + Part(cursor)), cancel);
    rows.AddRange(Items(page).Where(row => ids.Add(Get(row, "id"))));
    cursor = Get(page, "nextCursor");
    if (cursor != "" && !cursors.Add(cursor)) throw new IOException(UiLanguage.Text("대화 목록 페이지 응답이 반복됩니다."));
   } while (cursor != "");
   return rows;
  }
  public void Dispose() {
   http.Dispose();
   if (process == null) return;
   try { if (!process.HasExited) { process.Kill(); process.WaitForExit(3000); } }
   catch (InvalidOperationException) {}
   finally { process.Dispose(); }
  }
 }
}
