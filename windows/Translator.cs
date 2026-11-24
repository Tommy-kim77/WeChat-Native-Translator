using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace NativeTranslator {
 sealed class Translator : IDisposable {
  static string KeyPath { get { return Path.Combine(Engine.Data, "deepl-key"); } }
  readonly HttpClient http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(20) };
  public string Key { get; private set; }
  public Translator(bool loadKey = true) {
   Key = "";
   if (loadKey && File.Exists(KeyPath)) {
    try { Key = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(KeyPath), null, DataProtectionScope.CurrentUser)); }
    catch (CryptographicException) {}
    catch (IOException) {}
    catch (UnauthorizedAccessException) {}
   }
  }
  public void SetKey(string value) {
   Directory.CreateDirectory(Engine.Data);
   File.WriteAllBytes(KeyPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
   Key = value;
  }
  public async Task<string> Translate(string text, string target, CancellationToken cancel) {
   var key = Key;
   if (key == "") throw new InvalidOperationException(UiLanguage.Text("언어 설정에서 DeepL API 키를 저장하세요."));
   var host = key.EndsWith(":fx", StringComparison.OrdinalIgnoreCase) ? "api-free.deepl.com" : "api.deepl.com";
   var json = new JavaScriptSerializer();
   using (var req = new HttpRequestMessage(HttpMethod.Post, "https://" + host + "/v2/translate")) {
    req.Headers.TryAddWithoutValidation("Authorization", "DeepL-Auth-Key " + key);
    req.Content = new StringContent(json.Serialize(new { text = new[] { text }, target_lang = target }), Encoding.UTF8, "application/json");
    using (var response = await http.SendAsync(req, cancel)) {
     if (!response.IsSuccessStatusCode) throw new IOException(UiLanguage.Text("DeepL 요청 실패 (") + (int)response.StatusCode + ")");
     var data = json.Deserialize<Dictionary<string, object>>(await response.Content.ReadAsStringAsync());
     var translated = Engine.Get(Engine.Items(new Dictionary<string, object> { { "items", data["translations"] } }).Single(), "text");
     if (string.IsNullOrWhiteSpace(translated)) throw new IOException(UiLanguage.Text("DeepL 번역 결과가 비어 있습니다."));
     return translated;
    }
   }
  }
  public void Dispose() { http.Dispose(); }
 }
}
