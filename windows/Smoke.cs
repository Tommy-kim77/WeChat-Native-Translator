using System;
using System.IO;
using System.Linq;
using System.Threading;
using NativeTranslator;

static class Smoke {
 public static int Run(string report, bool verifyQr = false) {
  var data = Path.Combine(Path.GetTempPath(), "WeChatNativeTranslator-smoke-" + Guid.NewGuid().ToString("N"));
  try {
   using (var engine = new Engine(data))
   using (var timeout = new CancellationTokenSource(20000)) {
    var token = timeout.Token;
    engine.Start(token).GetAwaiter().GetResult();
    if (Engine.Items(engine.Json("/accounts", token).GetAwaiter().GetResult()).Any()) return 1;
    var profile = engine.Json("/accounts", token, new { id = "personal" }).GetAwaiter().GetResult();
    if (Engine.Get(profile, "id") != "personal") return 2;
    if (Engine.Get(profile, "authenticated").Equals("true", StringComparison.OrdinalIgnoreCase)) return 3;
    if (verifyQr) {
     var path = "/accounts/personal";
     var op = engine.Json(path + "/auth/login", token, new { }, Guid.NewGuid().ToString("N")).GetAwaiter().GetResult();
     var id = Engine.Get(op, "id");
     if (id == "") throw new IOException("Missing login operation");
     path += "/operations/" + Engine.Part(id);
     for (int i = 0; i < 16; ++i) {
      var state = Engine.Get(op, "state");
      var result = Engine.Object(op, "result");
      if (Engine.Get(result, "qrAvailable").Equals("true", StringComparison.OrdinalIgnoreCase)) {
       var generation = Engine.Get(result, "qrGeneration");
       using (var qr = engine.Request(path + "/qr?generation=" + (generation == "" ? "1" : Engine.Part(generation)), token).GetAwaiter().GetResult()) {
        qr.Content.LoadIntoBufferAsync(1048576).GetAwaiter().GetResult();
        var bytes = qr.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
        if (!bytes.Take(8).SequenceEqual(new byte[] { 137,80,78,71,13,10,26,10 })) throw new IOException("Invalid QR image");
       }
       using (engine.Request(path, token, System.Net.Http.HttpMethod.Delete).GetAwaiter().GetResult()) {}
       File.WriteAllText(report, "PASS: Windows native QR was generated, validated as PNG and cancelled without signing in.");
       return 0;
      }
      if (new[] {"failed","cancelled","rejected","expired","needs_login"}.Contains(state)) throw new IOException("QR operation " + state);
      Thread.Sleep(750);
      op = engine.Json(path, token).GetAwaiter().GetResult();
     }
     throw new IOException("QR generation timed out");
    }
    File.WriteAllText(report, "PASS: embedded Windows engine starts and authenticates its localhost API with an isolated profile.");
   }
   return 0;
  } catch (Exception e) {
   File.WriteAllText(report, e.GetType().Name + ": " + e.Message);
   return 4;
  } finally {
   try {
    if (Directory.Exists(data) && Path.GetDirectoryName(Path.GetFullPath(data)) == Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar))
     Directory.Delete(data, true);
   } catch (IOException) {} catch (UnauthorizedAccessException) {}
  }
 }
}
