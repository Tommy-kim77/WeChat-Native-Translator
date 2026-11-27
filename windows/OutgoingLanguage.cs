using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace NativeTranslator {
 // Composer policy for Korean, English and Chinese; no translation request is needed to detect them.
 static class OutgoingLanguage {
  static readonly Regex ProtectedText = new Regex(@"https?://[^\s<>]+|www\.[^\s<>]+|@[^@\r\n\u2005]+\u2005",RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
  static readonly Regex Words = new Regex(@"[A-Za-z0-9_]+(?:[.'’/+\-][A-Za-z0-9_]+)*|[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]+|[\u3400-\u9FFF]+");
  static readonly HashSet<string> EnglishCue = new HashSet<string>(new[]{"hi","hello","hey","please","thanks","thank","yes","no","sorry","can","could","did","have","how","when","what","check"},StringComparer.OrdinalIgnoreCase);
  static bool Between(int value,int first,int last) { return value>=first && value<=last; }
  public static bool RequiresTranslation(string text,string target) {
   var prose=ProtectedText.Replace(text," ");
   bool latin=false,korean=false,chinese=false;
   for(int i=0;i<prose.Length;i++) {
    bool letter=char.IsLetter(prose,i);
    int code=char.IsHighSurrogate(prose[i]) && i+1<prose.Length && char.IsLowSurrogate(prose[i+1]) ? char.ConvertToUtf32(prose,i++) : prose[i];
    if(!letter) continue;
    if(Between(code,0x41,0x5A) || Between(code,0x61,0x7A) || Between(code,0xC0,0x24F) || Between(code,0x1E00,0x1EFF) || Between(code,0xFF21,0xFF3A) || Between(code,0xFF41,0xFF5A)) latin=true;
    else if(Between(code,0x1100,0x11FF) || Between(code,0x3130,0x318F) || Between(code,0xA960,0xA97F) || Between(code,0xAC00,0xD7FF)) korean=true;
    else if(Between(code,0x3400,0x9FFF) || Between(code,0xF900,0xFAFF) || Between(code,0x20000,0x3134F)) chinese=true;
    else return true;
   }
   if(!latin && !korean && !chinese) return false;
   var language=target.Split('-')[0].ToUpperInvariant();
   if(language=="EN") return korean || chinese;
   if(language=="KO") return chinese || !korean || (latin && HasEnglishPhrase(prose));
   if(language=="ZH") return korean || !chinese || (latin && HasEnglishPhrase(prose));
   return true;
  }
  static bool HasEnglishPhrase(string text) {
   int run=0;
   foreach(Match match in Words.Matches(text)) {
    var word=match.Value;
    if(EnglishCue.Contains(word)) return true;
    bool english=word=="I" || !char.IsUpper(word[0]);
    foreach(char c in word) if(!((c>='A' && c<='Z') || (c>='a' && c<='z'))) english=false;
    run=english ? run+1 : 0;
    if(run>=3) return true;
   }
   return false;
  }
 }
}
