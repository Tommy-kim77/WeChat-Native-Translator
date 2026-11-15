using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace NativeTranslator {
 sealed class TranslationStore {
  readonly string directory;
  public TranslationStore(string profile) {
   directory = Path.Combine(profile, "translations-v1");
  }
  string EntryPath(string key) {
   using (var hash = SHA256.Create())
    return Path.Combine(directory, BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(key))).Replace("-", ""));
  }
  public string Read(string key) {
   var path = EntryPath(key);
   if (!File.Exists(path)) return null;
   try {
    return Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser));
   } catch (CryptographicException) { return null; }
   catch (IOException) { return null; }
   catch (UnauthorizedAccessException) { return null; }
  }
  public void Save(string key, string translation) {
   Engine.PrivateDirectory(directory);
   var path = EntryPath(key);
   if (File.Exists(path) && Read(key) != null) return;
   var temp = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
   try {
    File.WriteAllBytes(temp, ProtectedData.Protect(Encoding.UTF8.GetBytes(translation), null, DataProtectionScope.CurrentUser));
    if (File.Exists(path)) File.Replace(temp, path, null);
    else File.Move(temp, path);
   } finally { if (File.Exists(temp)) File.Delete(temp); }
  }
 }
}
