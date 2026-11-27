using System;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;

namespace NativeTranslator {
 static class Package {
  public const string Version = "0.1.37";
  const string EngineHash = "820ac63a769dd673958e56bd835ff5b6fffb5764269e0cb60b097869e1654a31";
  static string Hash(Stream input) {
   using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
  }
  static bool Matches(string path) {
   if (!File.Exists(path)) return false;
   if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException(UiLanguage.Text("엔진 경로가 올바르지 않습니다."));
   using (var file = File.OpenRead(path)) return Hash(file) == EngineHash;
  }
  public static string EnginePath(string dataDirectory) {
   var runtime = Path.Combine(dataDirectory, "engine-0.1.26-" + EngineHash.Substring(0, 12));
   Engine.PrivateDirectory(runtime);
   var path = Path.Combine(runtime, "wx.exe");
   if (!Matches(path)) {
    var temp = Path.Combine(runtime, Guid.NewGuid().ToString("N") + ".tmp");
    try {
     using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("engine.wx"))
     using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) source.CopyTo(output);
     if (!Matches(temp)) throw new IOException(UiLanguage.Text("내장 엔진 무결성 검사 실패"));
     if (File.Exists(path)) File.Replace(temp, path, null);
     else File.Move(temp, path);
    } finally { if (File.Exists(temp)) File.Delete(temp); }
   }
   return path;
  }
 }
}
