using System;
using System.Collections.Generic;
using System.Linq;

namespace NativeTranslator {
 sealed partial class Chat {
  void ShowDesignExample() {
   room = "sample-office";
   ownAvatarId = "self";
   inventory = new List<Room> {
    new Room { Id=room,Name="深圳电子厂 (왕사장)",Unread="1",Version="",Preview="你好，请问产品什么时候可以发货？",Time="19:15" },
    new Room { Id="demo-sales",Name="广州贸易公司",Unread="",Version="",Preview="好的，明天确认后…",Time="18:40" },
    new Room { Id="demo-manager",Name="李经理",Unread="",Version="",Preview="发票已经开好了。",Time="16:20" },
    new Room { Id="demo@chatroom",Name="产品供应群 (5)",Unread="",Version="",Preview="新款的样品下周到货。",Time="09:30" }
   };
   Populate("");
   rooms.SelectedIndex = 0;
   ActiveControl = rooms;
   title.Text = inventory[0].Name;
   status.Text = "Enter 번역 → Enter 전송 · Shift+Enter 줄바꿈";
   shown = new List<IDictionary<string,object>> {
    ExampleMessage("1","incoming","你好，请问产品什么时候可以发货？","19:10"),
    ExampleMessage("2","outgoing","내일 발송할 예정입니다.","19:15"),
    ExampleMessage("3","incoming","好的，谢谢！","19:18")
   };
   translations[TranslationKey(shown[0])] = "안녕하세요. 제품은 언제 발송할 수 있나요?";
   translations[TranslationKey(shown[1])] = "预计明天发货。";
   translations[TranslationKey(shown[2])] = "좋습니다. 감사합니다!";
   Render();
  }
  static IDictionary<string,object> ExampleMessage(string id,string direction,string body,string time) {
   return new Dictionary<string,object> {{"id",id},{"type",1},{"direction",direction},{"body",body},
    {"createdAt",DateTime.Today.ToString("yyyy-MM-dd")+"T"+time+":00"}};
  }
 }
}
