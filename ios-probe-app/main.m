#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#import "WeChatProbe-Swift.h"

#import <Security/Security.h>
#include <string.h>

// Secret credentials are held in the device Keychain, not in chat JSON or app files.
static NSDictionary *WeChatKeychainQuery(void) {
 return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
          (__bridge id)kSecAttrService:@"kr.probedigital.wechatiosprobe.auth",
          (__bridge id)kSecAttrAccount:@"primary"};
}
int32_t wechat_keychain_save(const uint8_t *bytes, size_t len) {
 if (!bytes || !len || len > 8*1024*1024) return (int32_t)errSecParam;
 NSData *data=[NSData dataWithBytes:bytes length:len];
 NSMutableDictionary *query=[WeChatKeychainQuery() mutableCopy];
 OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)query,
              (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});
 if (status==errSecItemNotFound) {
  query[(__bridge id)kSecValueData]=data;
  query[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
  status=SecItemAdd((__bridge CFDictionaryRef)query,NULL);
 }
 return (int32_t)status;
}
intptr_t wechat_keychain_load(uint8_t *buffer, size_t capacity) {
 if (!buffer || !capacity) return (intptr_t)errSecParam;
 NSMutableDictionary *query=[WeChatKeychainQuery() mutableCopy];
 query[(__bridge id)kSecReturnData]=@YES;
 query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
 CFTypeRef value=NULL;
 OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&value);
 if (status!=errSecSuccess) return (intptr_t)status;
 NSData *data=CFBridgingRelease(value);
 if (data.length>capacity) return (intptr_t)errSecBufferTooSmall;
 memcpy(buffer,data.bytes,data.length);
 return (intptr_t)data.length;
}


static UIColor *WXGrayBackground(void) {
 return [UIColor colorWithRed:0.93 green:0.93 blue:0.93 alpha:1];
}
static UIColor *WXMessageGreen(void) {
 return [UIColor colorWithRed:0.59 green:0.91 blue:0.36 alpha:1];
}
static UIImage *WXThumbnail(UIImage *source,CGFloat size) {
 if (!source) return nil;
 UIGraphicsImageRenderer *render=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size,size)];
 return [render imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
  UIBezierPath *clip=[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,size,size) cornerRadius:6];
  [clip addClip];
  CGFloat aspect=MAX(size/source.size.width,size/source.size.height);
  CGFloat w=source.size.width*aspect,h=source.size.height*aspect;
  [source drawInRect:CGRectMake((size-w)/2,(size-h)/2,w,h)];
 }];
}
static NSDictionary *WXLoadDirectory(void) {
 NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"wechat-ios-directory.json"];
 NSData *data=[NSData dataWithContentsOfFile:path];
 if (!data) return @{};
 id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
 return [parsed isKindOfClass:NSDictionary.class]?parsed:@{};
}
static NSString *WXDisplayName(NSString *peer,NSDictionary *directory) {
 if ([peer isEqualToString:@"filehelper"]) return @"파일 전송";
 if ([peer isEqualToString:@"weixin"]) return @"WeChat 팀";
 NSString *name=[directory[peer][@"name"] isKindOfClass:NSString.class]?directory[peer][@"name"]:nil;
 return name.length ? name : (peer?:@"");
}
static UIImage *WXAvatar(NSString *peer,NSDictionary *directory) {
 NSString *filename=[directory[peer][@"avatar_file"] isKindOfClass:NSString.class]?directory[peer][@"avatar_file"]:nil;
 if (!filename.length || ![filename hasPrefix:@"wechat-ios-avatar-"] || [filename containsString:@"/"]) return nil;
 return [UIImage imageWithContentsOfFile:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
}


// Accepted local sends are stored separately because sync snapshots overwrite chats.json.
// The storage is app-local, never used for network transmission or automatic resends.
static NSString *WXAppDataPath(NSString *name) {
 NSURL *base=[[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
 if (!base || !name.length) return nil;
 [[NSFileManager defaultManager] createDirectoryAtURL:base withIntermediateDirectories:YES attributes:nil error:nil];
 return [[base URLByAppendingPathComponent:name] path];
}
static NSArray *WXArrayAtPath(NSString *path) {
 if (!path.length) return @[];
 NSData *raw=[NSData dataWithContentsOfFile:path];
 if (!raw.length) return @[];
 id parsed=[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
 return [parsed isKindOfClass:NSArray.class]?parsed:@[];
}
static BOOL WXWriteJSON(NSArray *records,NSString *path) {
 if (!path.length) return NO;
 NSData *bytes=[NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
 if (!bytes || ![bytes writeToFile:path atomically:YES]) return NO;
 [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:path error:nil];
 return YES;
}
// Successful Korean translations persist across chat navigation and app restarts.
// Key is original message text; equal originals share the same Korean translation.
// Never cache error placeholders or secrets from the authenticated transport.
static NSString *WXMessageDeletePath(void) { return WXAppDataPath(@"hidden-messages.json"); }
static NSString *WXMessageKey(NSString *peer,NSDictionary *m) {
 NSString *local=[m[@"local_id"] isKindOfClass:NSString.class]?m[@"local_id"]:nil;
 if (local.length) return [@"local:" stringByAppendingString:local];
 NSNumber *stamp=[m[@"timestamp"] isKindOfClass:NSNumber.class]?m[@"timestamp"]:@0;
 NSString *text=[m[@"text"] isKindOfClass:NSString.class]?m[@"text"]:@"";
 NSString *outgoing=[m[@"outgoing"] boolValue]?@"out":@"in";
 NSString *combined=[NSString stringWithFormat:@"%@|%@|%@|%@",peer?:@"",stamp,outgoing,text];
 NSData *data=[combined dataUsingEncoding:NSUTF8StringEncoding];
 unsigned char digest[CC_SHA256_DIGEST_LENGTH];
 CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
 NSMutableString *key=[NSMutableString stringWithString:@"server:"];
 for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [key appendFormat:@"%02x",digest[i]];
 return key;
}
static NSSet *WXHiddenMessageKeys(void) {
 return [NSSet setWithArray:WXArrayAtPath(WXMessageDeletePath())];
}
static BOOL WXHideMessage(NSString *peer,NSDictionary *message) {
 NSString *key=WXMessageKey(peer,message);
 NSMutableSet *hidden=[WXHiddenMessageKeys() mutableCopy];
 [hidden addObject:key];
 return WXWriteJSON([hidden.allObjects sortedArrayUsingSelector:@selector(compare:)],WXMessageDeletePath());
}
static NSString *WXTranslationCachePath(void) {
 return WXAppDataPath(@"translated-ko-v1.json");
}
static NSMutableDictionary<NSString *,NSString *> *WXReadTranslations(void) {
 NSData *raw=[NSData dataWithContentsOfFile:WXTranslationCachePath()];
 NSDictionary *decoded=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil]:nil;
 NSMutableDictionary *valid=[NSMutableDictionary new];
 if (![decoded isKindOfClass:NSDictionary.class]) return valid;
 for (id key in decoded) {
  id value=decoded[key];
  if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class] &&
      [key length]<=65536 && [value length]<=65536) valid[key]=value;
 }
 return valid;
}
static BOOL WXSaveTranslation(NSString *original,NSString *translated) {
 if (!original.length || !translated.length ||
     original.length>65536 || translated.length>65536) return NO;
 NSMutableDictionary *cached=WXReadTranslations();
 cached[original]=translated;
 // Bound the cache; on overflow retain only the newest entry, avoiding
 // unbounded storage growth. A proper SQLite cache can replace this later.
 if (cached.count>10000) {
  cached=[@{original:translated} mutableCopy];
 }
 NSString *path=WXTranslationCachePath();
 NSData *payload=[NSJSONSerialization dataWithJSONObject:cached options:0 error:nil];
 if (!payload || payload.length>8*1024*1024 || ![payload writeToFile:path atomically:YES]) return NO;
 [[NSFileManager defaultManager] setAttributes:
   @{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
   ofItemAtPath:path error:nil];
 return YES;
}
static NSString *WXOutgoingPath(void) { return WXAppDataPath(@"accepted-outgoing.json"); }
static NSString *WXHiddenPath(void) { return WXAppDataPath(@"hidden-chats.json"); }
static NSSet<NSString *> *WXHiddenPeers(void) {
 NSMutableSet<NSString *> *result=[NSMutableSet new];
 for (id item in WXArrayAtPath(WXHiddenPath())) if ([item isKindOfClass:NSString.class]) [result addObject:item];
 return result;
}
static BOOL WXSetHidden(NSString *peer, BOOL hidden) {
 if (!peer.length) return NO;
 NSMutableSet<NSString *> *set=[WXHiddenPeers() mutableCopy];
 if (hidden) [set addObject:peer]; else [set removeObject:peer];
 return WXWriteJSON([set.allObjects sortedArrayUsingSelector:@selector(compare:)],WXHiddenPath());
}
static NSDictionary *WXLastTextReceipt(NSString *peer,NSString *message) {
 NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"wechat-ios-last-text-receipt.json"];
 NSData *raw=[NSData dataWithContentsOfFile:path];
 NSDictionary *receipt=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil]:nil;
 if (![receipt isKindOfClass:NSDictionary.class] ||
     ![receipt[@"peer"] isEqualToString:peer]) return nil;
 NSData *source=[message dataUsingEncoding:NSUTF8StringEncoding];
 unsigned char digest[CC_SHA256_DIGEST_LENGTH];
 CC_SHA256(source.bytes,(CC_LONG)source.length,digest);
 NSMutableString *hash=[NSMutableString new];
 for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hash appendFormat:@"%02x",digest[i]];
 if (![receipt[@"sha256"] isEqualToString:hash]) return nil;
 NSNumber *time=receipt[@"created_at"];
 if (![time isKindOfClass:NSNumber.class] ||
     llabs((long long)NSDate.date.timeIntervalSince1970-time.longLongValue)>120) return nil;
 return receipt;
}
static BOOL WXAcceptedOutgoingSaveWithReceipt(NSString *peer,NSString *message,NSDictionary *receipt) {
 if (!peer.length || !message.length) return NO;
 NSMutableArray *records=[WXArrayAtPath(WXOutgoingPath()) mutableCopy];
 NSMutableDictionary *entry=[@{
   @"peer":peer,@"text":message,@"sender":@"Me",
   @"outgoing":@YES,@"accepted_local":@YES,
   @"timestamp":@((long long)NSDate.date.timeIntervalSince1970),
   @"local_id":NSUUID.UUID.UUIDString
 } mutableCopy];
 if (receipt) {
  for (NSString *field in @[@"server_id",@"created_at"]) {
   if (receipt[field]) entry[field]=receipt[field];
  }
  if (receipt[@"local_id"]) entry[@"send_local_id"]=receipt[@"local_id"];
 }
 [records addObject:entry];
 return WXWriteJSON(records,WXOutgoingPath());
}
static BOOL WXMarkServerRecalled(NSString *serverID) {
 if (!serverID.length) return NO;
 NSMutableArray *records=[WXArrayAtPath(WXOutgoingPath()) mutableCopy];
 BOOL changed=NO;
 for (NSUInteger i=0;i<records.count;i++) {
  NSDictionary *r=records[i];
  if ([r[@"server_id"] isEqualToString:serverID]) {
   NSMutableDictionary *item=[r mutableCopy];item[@"recalled"]=@YES;records[i]=item;changed=YES;
  }
 }
 return changed && WXWriteJSON(records,WXOutgoingPath());
}
static BOOL WXAcceptedOutgoingSave(NSString *peer,NSString *message) {
 return WXAcceptedOutgoingSaveWithReceipt(peer,message,nil);
}

static NSArray *WXLoadMergedChats(void) {
 NSArray *remote=WXArrayAtPath([NSTemporaryDirectory() stringByAppendingPathComponent:@"wechat-ios-chats.json"]);
 NSArray *accepted=WXArrayAtPath(WXOutgoingPath());
 NSMutableSet *recalledServerIds=[NSMutableSet new];
 for (NSDictionary *record in accepted) {
  if ([record[@"recalled"] boolValue] && [record[@"server_id"] isKindOfClass:NSString.class])
   [recalledServerIds addObject:record[@"server_id"]];
 }
 NSMutableDictionary<NSString *,NSMutableDictionary *> *byPeer=[NSMutableDictionary new];
 for (id item in remote) {
  if (![item isKindOfClass:NSDictionary.class]) continue;
  NSString *peer=[item[@"title"] isKindOfClass:NSString.class]?item[@"title"]:nil;
  if (!peer.length) continue;
  NSMutableDictionary *chat=[item mutableCopy];
  NSMutableArray *remoteMessages=[NSMutableArray new];
  for (NSDictionary *message in ([item[@"messages"] isKindOfClass:NSArray.class]?item[@"messages"]:@[])) {
   if (message[@"server_id"] && [recalledServerIds containsObject:message[@"server_id"]]) continue;
   [remoteMessages addObject:message];
  }
  chat[@"messages"]=remoteMessages;
  byPeer[peer]=chat;
 }
 for (id raw in accepted) {
  if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"accepted_local"] boolValue] || [raw[@"recalled"] boolValue]) continue;
  NSString *peer=[raw[@"peer"] isKindOfClass:NSString.class]?raw[@"peer"]:nil;
  NSString *text=[raw[@"text"] isKindOfClass:NSString.class]?raw[@"text"]:nil;
  NSNumber *when=[raw[@"timestamp"] isKindOfClass:NSNumber.class]?raw[@"timestamp"]:nil;
  if (!peer.length || !text.length || !when) continue;
  NSMutableDictionary *chat=byPeer[peer];
  if (!chat) { chat=[@{@"title":peer,@"messages":[NSMutableArray new]} mutableCopy]; byPeer[peer]=chat; }
  NSMutableArray *messages=chat[@"messages"];
  BOOL matched=NO;
  for (NSDictionary *msg in messages) {
   if (![msg[@"outgoing"] boolValue] || [msg[@"accepted_local"] boolValue]) continue;
   NSString *body=[msg[@"text"] isKindOfClass:NSString.class]?msg[@"text"]:nil;
   NSNumber *time=[msg[@"timestamp"] isKindOfClass:NSNumber.class]?msg[@"timestamp"]:nil;
   if ([body isEqualToString:text] && time && llabs(time.longLongValue-when.longLongValue)<=180) {
    matched=YES; break;
   }
  }
  if (!matched) [messages addObject:raw];
 }
 NSMutableArray *output=[NSMutableArray new];
 for (NSMutableDictionary *chat in byPeer.allValues) {
  NSArray *messages=[chat[@"messages"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
   return [a[@"timestamp"] compare:b[@"timestamp"]];
  }];
  NSSet *hiddenMessages=WXHiddenMessageKeys();
  NSMutableArray *visible=[NSMutableArray new];
  NSString *peer=chat[@"title"];
  for (NSDictionary *message in messages) {
   if (![hiddenMessages containsObject:WXMessageKey(peer,message)]) [visible addObject:message];
  }
  chat[@"messages"]=visible;
  NSDictionary *last=visible.lastObject;
  NSString *preview=@"";
  // Generic binary placeholders are internal protocol stand-ins, not text
  // received from a contact. Prefer the newest actual text for the list.
  for (NSDictionary *entry in visible.reverseObjectEnumerator) {
   NSString *candidate=[entry[@"text"] isKindOfClass:NSString.class]?entry[@"text"]:@"";
   if (candidate.length && ![candidate isEqualToString:@"[Non-text message]"] &&
       ![candidate isEqualToString:@"첨부·미디어 메시지 (미리보기 미지원)"]) {
    preview=candidate;break;
   }
  }
  if (!preview.length && visible.count) preview=@"미디어 메시지";
  chat[@"preview"]=preview;
  chat[@"last_timestamp"]=last[@"timestamp"]?:@0;
  [output addObject:chat];
 }
 [output sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
  return [b[@"last_timestamp"] compare:a[@"last_timestamp"]];
 }];
 return output;
}

extern int wechat_ios_qr_probe(void);
extern int wechat_ios_send_text(const char *destination, const char *content);
extern int wechat_ios_fetch_room_members(const char *room);
extern int wechat_ios_recall_sent_text(const char *peer,const char *serverID,uint32_t localID,uint32_t createdAt);
extern int wechat_ios_send_media_file(const char *destination,const char *original,
 const char *standard,const char *thumbnail,const char *name,int imageMode);


@interface WXGroupInfoController : UIViewController
@property(nonatomic,copy) NSString *peer;
@property(nonatomic,copy) NSString *displayName;
@property(nonatomic,strong) NSArray<NSDictionary *> *members;
@property(nonatomic,copy) void(^selectMember)(NSDictionary *);
@property(nonatomic,strong) UIScrollView *scroll;
@end

@implementation WXGroupInfoController
- (instancetype)initWithPeer:(NSString *)peer name:(NSString *)name members:(NSArray *)members
 selection:(void (^)(NSDictionary *member))selection {
 if ((self=[super init])) {
  _peer=[peer copy];_displayName=[name copy];_members=[members copy];_selectMember=[selection copy];
 }
 return self;
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
 UILabel *label=[UILabel new];label.text=text;
 label.font=[UIFont systemFontOfSize:size];
 label.textColor=color?:UIColor.labelColor;
 return label;
}
- (void)infoNotice:(NSString *)message {
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"기능 안내"
  message:message preferredStyle:UIAlertControllerStyleAlert];
 [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
 [self presentViewController:alert animated:YES completion:nil];
}
- (void)unsupported:(UIButton *)sender {
 [self infoNotice:@"현재 iPhone 개발 앱에서는 이 메뉴의 서버 설정 변경이 지원되지 않습니다. 공식 WeChat의 설정은 변경되지 않습니다."];
}
- (void)memberTapped:(UIButton *)sender {
 NSInteger i=sender.tag-2000;
 if (i<0 || i>=self.members.count) return;
 if (self.selectMember) self.selectMember(self.members[i]);
 [self.navigationController popViewControllerAnimated:YES];
}
- (void)toggleChanged:(UISwitch *)sender {
 NSString *setting=@[@"mute",@"pin",@"address",@"nicknames"][MIN(MAX(0,sender.tag-3000),3)];
 NSString *key=[NSString stringWithFormat:@"wx-local-%@-%@",setting,self.peer];
 [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];
}
- (UIView *)settingRow:(NSString *)title value:(NSString *)value height:(CGFloat)height action:(SEL)action {
 UIView *row=[UIView new];row.translatesAutoresizingMaskIntoConstraints=NO;
 row.backgroundColor=UIColor.whiteColor;
 UILabel *left=[self label:title size:16 color:UIColor.labelColor];
 left.translatesAutoresizingMaskIntoConstraints=NO;
 [row addSubview:left];
 UILabel *right=[self label:value?:@"" size:15 color:UIColor.secondaryLabelColor];
 right.textAlignment=NSTextAlignmentRight;right.lineBreakMode=NSLineBreakByTruncatingTail;
 right.translatesAutoresizingMaskIntoConstraints=NO;[row addSubview:right];
 UILabel *arrow=[self label:@"›" size:25 color:UIColor.tertiaryLabelColor];
 arrow.translatesAutoresizingMaskIntoConstraints=NO;[row addSubview:arrow];
 UIButton *touch=[UIButton buttonWithType:UIButtonTypeCustom];
 touch.translatesAutoresizingMaskIntoConstraints=NO;
 [touch addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
 [row addSubview:touch];
 [NSLayoutConstraint activateConstraints:@[
  [row.heightAnchor constraintEqualToConstant:height],
  [left.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
  [left.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [left.widthAnchor constraintEqualToConstant:116],
  [arrow.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
  [arrow.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [right.trailingAnchor constraintEqualToAnchor:arrow.leadingAnchor constant:-8],
  [right.leadingAnchor constraintGreaterThanOrEqualToAnchor:left.trailingAnchor constant:8],
  [right.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [touch.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
  [touch.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
  [touch.topAnchor constraintEqualToAnchor:row.topAnchor],
  [touch.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]]];
 return row;
}
- (UIView *)switchRow:(NSString *)title index:(NSInteger)index {
 UIView *row=[UIView new];row.backgroundColor=UIColor.whiteColor;
 row.translatesAutoresizingMaskIntoConstraints=NO;
 UILabel *caption=[self label:title size:16 color:UIColor.labelColor];
 caption.translatesAutoresizingMaskIntoConstraints=NO;[row addSubview:caption];
 UISwitch *toggle=[UISwitch new];toggle.tag=3000+index;toggle.translatesAutoresizingMaskIntoConstraints=NO;
 NSString *setting=@[@"mute",@"pin",@"address",@"nicknames"][index];
 toggle.on=[[NSUserDefaults standardUserDefaults]
    boolForKey:[NSString stringWithFormat:@"wx-local-%@-%@",setting,self.peer]];
 [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
 [row addSubview:toggle];
 [NSLayoutConstraint activateConstraints:@[
  [row.heightAnchor constraintEqualToConstant:52],
  [caption.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
  [caption.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
  [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
 return row;
}
- (void)viewDidLoad {
 [super viewDidLoad];
 self.title=[NSString stringWithFormat:@"채팅 정보(%lu)",(unsigned long)self.members.count];
 self.view.backgroundColor=[UIColor colorWithWhite:.94 alpha:1];
 self.scroll=[UIScrollView new];self.scroll.translatesAutoresizingMaskIntoConstraints=NO;
 [self.view addSubview:self.scroll];
 [NSLayoutConstraint activateConstraints:@[
  [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
  [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
  [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
  [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
 UIStackView *content=[UIStackView new];content.axis=UILayoutConstraintAxisVertical;
 content.spacing=0;content.translatesAutoresizingMaskIntoConstraints=NO;
 [self.scroll addSubview:content];
 [NSLayoutConstraint activateConstraints:@[
  [content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor],
  [content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor],
  [content.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor],
  [content.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor],
  [content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor]]];
 UIView *gridContainer=[UIView new];gridContainer.backgroundColor=UIColor.whiteColor;
 gridContainer.translatesAutoresizingMaskIntoConstraints=NO;[content addArrangedSubview:gridContainer];
 UIStackView *grid=[UIStackView new];grid.axis=UILayoutConstraintAxisVertical;grid.spacing=14;
 grid.translatesAutoresizingMaskIntoConstraints=NO;[gridContainer addSubview:grid];
 [NSLayoutConstraint activateConstraints:@[
  [grid.topAnchor constraintEqualToAnchor:gridContainer.topAnchor constant:18],
  [grid.bottomAnchor constraintEqualToAnchor:gridContainer.bottomAnchor constant:-18],
  [grid.leadingAnchor constraintEqualToAnchor:gridContainer.leadingAnchor constant:12],
  [grid.trailingAnchor constraintEqualToAnchor:gridContainer.trailingAnchor constant:-12]]];
 // Six columns as the official WeChat group information layout.
 NSUInteger count=MIN((NSUInteger)80,self.members.count);
 NSUInteger slots=count+1;
 for (NSUInteger offset=0;offset<slots;offset+=6) {
  UIStackView *line=[UIStackView new];line.axis=UILayoutConstraintAxisHorizontal;
  line.alignment=UIStackViewAlignmentTop;line.distribution=UIStackViewDistributionFillEqually;
  line.spacing=4;[grid addArrangedSubview:line];
  for (NSUInteger col=0;col<6;col++) {
   NSUInteger idx=offset+col;
   UIView *slot=[UIView new];[line addArrangedSubview:slot];
   [slot.heightAnchor constraintEqualToConstant:89].active=YES;
   if (idx>=slots) continue;
   BOOL add=idx==count;
   NSDictionary *member=add?@{}:self.members[idx];
   NSString *name=add?@"":([member[@"name"] isKindOfClass:NSString.class]?member[@"name"]:@"");
   NSString *filename=[member[@"avatar_file"] isKindOfClass:NSString.class]?member[@"avatar_file"]:nil;
   UIImage *photo=nil;
   if (filename.length && [filename hasPrefix:@"wechat-ios-avatar-"] && ![filename containsString:@"/"])
    photo=[UIImage imageWithContentsOfFile:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
   UIImageView *avatar=[[UIImageView alloc] initWithImage:photo?:[UIImage systemImageNamed:add?@"plus":@"person.crop.square.fill"]];
   avatar.contentMode=photo?UIViewContentModeScaleAspectFill:UIViewContentModeScaleAspectFit;
   avatar.tintColor=UIColor.systemGray3Color;
   avatar.backgroundColor=photo?UIColor.clearColor:UIColor.systemGray6Color;
   avatar.layer.cornerRadius=5;avatar.clipsToBounds=YES;
   avatar.translatesAutoresizingMaskIntoConstraints=NO;[slot addSubview:avatar];
   UILabel *nameLabel=[self label:name size:11 color:UIColor.secondaryLabelColor];
   nameLabel.textAlignment=NSTextAlignmentCenter;nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;
   nameLabel.translatesAutoresizingMaskIntoConstraints=NO;[slot addSubview:nameLabel];
   UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];button.tag=2000+idx;
   button.translatesAutoresizingMaskIntoConstraints=NO;[slot addSubview:button];
   [button addTarget:self action:add?@selector(unsupported:):@selector(memberTapped:) forControlEvents:UIControlEventTouchUpInside];
   [NSLayoutConstraint activateConstraints:@[
    [avatar.topAnchor constraintEqualToAnchor:slot.topAnchor],
    [avatar.centerXAnchor constraintEqualToAnchor:slot.centerXAnchor],
    [avatar.widthAnchor constraintEqualToConstant:48],
    [avatar.heightAnchor constraintEqualToConstant:48],
    [nameLabel.topAnchor constraintEqualToAnchor:avatar.bottomAnchor constant:5],
    [nameLabel.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor],
    [nameLabel.trailingAnchor constraintEqualToAnchor:slot.trailingAnchor],
    [button.topAnchor constraintEqualToAnchor:slot.topAnchor],
    [button.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor],
    [button.trailingAnchor constraintEqualToAnchor:slot.trailingAnchor],
    [button.bottomAnchor constraintEqualToAnchor:nameLabel.bottomAnchor]]];
  }
 }
 UIView *gap=[UIView new];[content addArrangedSubview:gap];[gap.heightAnchor constraintEqualToConstant:12].active=YES;
 [content addArrangedSubview:[self settingRow:@"그룹 이름" value:self.displayName height:60 action:@selector(unsupported:)]];
 [content addArrangedSubview:[self settingRow:@"그룹 QR 코드" value:@"" height:55 action:@selector(unsupported:)]];
 [content addArrangedSubview:[self settingRow:@"그룹 알림" value:@"설정 예정" height:55 action:@selector(unsupported:)]];
 [content addArrangedSubview:[self settingRow:@"설명" value:@"" height:55 action:@selector(unsupported:)]];
 UIView *gap2=[UIView new];[content addArrangedSubview:gap2];[gap2.heightAnchor constraintEqualToConstant:12].active=YES;
 [content addArrangedSubview:[self settingRow:@"기록 검색" value:@"지원 예정" height:56 action:@selector(unsupported:)]];
 UIView *gap3=[UIView new];[content addArrangedSubview:gap3];[gap3.heightAnchor constraintEqualToConstant:12].active=YES;
 [content addArrangedSubview:[self switchRow:@"알림 음소거 (앱 내 설정)" index:0]];
 [content addArrangedSubview:[self switchRow:@"맨 위에 고정 (앱 내 설정)" index:1]];
 [content addArrangedSubview:[self switchRow:@"주소록에 저장 (앱 내 설정)" index:2]];
 UIView *gap4=[UIView new];[content addArrangedSubview:gap4];[gap4.heightAnchor constraintEqualToConstant:12].active=YES;
 [content addArrangedSubview:[self settingRow:@"그룹에서 내 별칭" value:@"지원 예정" height:55 action:@selector(unsupported:)]];
 [content addArrangedSubview:[self switchRow:@"멤버의 별명 표시 (앱 내 설정)" index:3]];
 UIView *gap5=[UIView new];[content addArrangedSubview:gap5];[gap5.heightAnchor constraintEqualToConstant:12].active=YES;
 [content addArrangedSubview:[self settingRow:@"배경" value:@"지원 예정" height:55 action:@selector(unsupported:)]];
 UILabel *note=[self label:@"일부 메뉴는 화면 구성만 적용했습니다. 앱 내 설정은 공식 WeChat 계정에 동기화되지 않습니다." size:12 color:UIColor.secondaryLabelColor];
 note.numberOfLines=0;note.textAlignment=NSTextAlignmentCenter;
 [content addArrangedSubview:note];
 [note.heightAnchor constraintGreaterThanOrEqualToConstant:62].active=YES;
}
@end

// Until media messages are decoded and rendered as attachments, suppress only
// the synthetic placeholder rows in the chat detail UI. This never modifies
// server synchronization or locally stored history.
static NSArray<NSDictionary *> *WXVisibleTextMessages(id raw) {
 if (![raw isKindOfClass:NSArray.class]) return @[];
 NSMutableArray<NSDictionary *> *visible=[NSMutableArray new];
 for (id item in (NSArray *)raw) {
  if (![item isKindOfClass:NSDictionary.class]) continue;
  NSString *text=[item[@"text"] isKindOfClass:NSString.class]?item[@"text"]:@"";
  if ([text isEqualToString:@"[Non-text message]"] ||
      [text isEqualToString:@"첨부·미디어 메시지 (미리보기 미지원)"]) continue;
  [visible addObject:item];
 }
 return visible;
}

@interface ChatDetailController : UIViewController <UITableViewDataSource, UITextViewDelegate,
UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate, UITableViewDelegate>
@property(nonatomic,strong) NSDictionary *chat;
@property(nonatomic,strong) NSDictionary *directory;
@property(nonatomic,strong) NSArray *messages;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UITextView *composer;
@property(nonatomic,strong) UIButton *sendButton;
@property(nonatomic,strong) UIButton *attachButton;
@property(nonatomic,assign) BOOL mediaBusy;
@property(nonatomic,strong) NSArray<NSDictionary *> *roomMembers;
@property(nonatomic,strong) UIButton *translateButton;
@property(nonatomic,strong) UITextView *previewLabel;
@property(nonatomic,assign) BOOL translationReady;
@property(nonatomic,copy) NSString *draftTranslation;
@property(nonatomic,strong) UISegmentedControl *receiveLanguage;
@property(nonatomic,strong) UISegmentedControl *sendLanguage;
@property(nonatomic,strong) UIView *composerArea;
@property(nonatomic,strong) WeChatTranslationBridge *translator;
@property(nonatomic,strong) WeChatTranslationBridge *draftTranslator;
@property(nonatomic,strong) UIViewController *draftWorker;
@property(nonatomic,strong) UIViewController *translationWorker;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *translated;
@property(nonatomic,strong) NSMutableSet<NSString *> *translationAttempted;
- (void)updateChat:(NSDictionary *)chat;
@end
@implementation ChatDetailController
- (instancetype)initWithChat:(NSDictionary *)chat {
 if ((self=[super init])) { _chat=chat; _directory=WXLoadDirectory(); _messages=WXVisibleTextMessages(chat[@"messages"]); }
 return self;
}
- (void)viewDidLoad {
 [super viewDidLoad];
 self.title=WXDisplayName(self.chat[@"title"],self.directory);
 if ([self.chat[@"title"] hasSuffix:@"@chatroom"]) {
  self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]
    initWithTitle:@"···" style:UIBarButtonItemStylePlain target:self action:@selector(openMembers)];
 }
 self.view.backgroundColor=WXGrayBackground();
 self.translated=WXReadTranslations();self.translationAttempted=[NSMutableSet new];
 self.translator=[WeChatTranslationBridge new];
 self.translationWorker=[self.translator makeWorkerViewController];
 [self addChildViewController:self.translationWorker];
 self.translationWorker.view.translatesAutoresizingMaskIntoConstraints=NO;
 [self.view addSubview:self.translationWorker.view];
 [NSLayoutConstraint activateConstraints:@[
 [self.translationWorker.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
 [self.translationWorker.view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
 [self.translationWorker.view.widthAnchor constraintEqualToConstant:1],
 [self.translationWorker.view.heightAnchor constraintEqualToConstant:1]]];
 [self.translationWorker didMoveToParentViewController:self];
 self.draftTranslator=[WeChatTranslationBridge new];
 self.draftWorker=[self.draftTranslator makeWorkerViewController];
 [self addChildViewController:self.draftWorker];
 self.draftWorker.view.translatesAutoresizingMaskIntoConstraints=NO;
 [self.view addSubview:self.draftWorker.view];
 [NSLayoutConstraint activateConstraints:@[
 [self.draftWorker.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
 [self.draftWorker.view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
 [self.draftWorker.view.widthAnchor constraintEqualToConstant:1],
 [self.draftWorker.view.heightAnchor constraintEqualToConstant:1]]];
 [self.draftWorker didMoveToParentViewController:self];

 UIStackView *languageBar=[UIStackView new];
 languageBar.axis=UILayoutConstraintAxisHorizontal; languageBar.spacing=8;
 languageBar.alignment=UIStackViewAlignmentCenter;
 languageBar.translatesAutoresizingMaskIntoConstraints=NO;
 UILabel *incoming=[UILabel new];
 incoming.text=@"영어·중국어 자동감지 → 한국어";
 incoming.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
 incoming.textColor=UIColor.secondaryLabelColor;
 [languageBar addArrangedSubview:incoming];
 [self.view addSubview:languageBar];

 self.table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
 self.table.translatesAutoresizingMaskIntoConstraints=NO;self.table.dataSource=self;self.table.delegate=(id<UITableViewDelegate>)self;
 self.table.separatorStyle=UITableViewCellSeparatorStyleNone;
 self.table.backgroundColor=WXGrayBackground();
 self.table.rowHeight=UITableViewAutomaticDimension;self.table.estimatedRowHeight=90;
 self.table.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
 self.table.contentInset=UIEdgeInsetsMake(0,0,14,0);
 [self.view addSubview:self.table];

 self.composerArea=[UIView new];self.composerArea.translatesAutoresizingMaskIntoConstraints=NO;
 self.composerArea.backgroundColor=[UIColor colorWithRed:0.965 green:0.965 blue:0.965 alpha:1];
 [self.view addSubview:self.composerArea];
 UILabel *draftLabel=[UILabel new];draftLabel.text=@"위챗 초안";draftLabel.font=[UIFont boldSystemFontOfSize:13];
 draftLabel.translatesAutoresizingMaskIntoConstraints=NO;
 self.composer=[UITextView new];self.composer.translatesAutoresizingMaskIntoConstraints=NO;
 self.composer.font=[UIFont systemFontOfSize:16];
 self.composer.delegate=self;
 self.composer.backgroundColor=UIColor.systemBackgroundColor;
 self.composer.layer.cornerRadius=8;self.composer.layer.borderWidth=.5;
 self.composer.layer.borderColor=UIColor.separatorColor.CGColor;
 self.sendLanguage=[[UISegmentedControl alloc] initWithItems:@[@"한국어",@"English",@"中文"]];
 self.sendLanguage.translatesAutoresizingMaskIntoConstraints=NO;
 self.sendLanguage.selectedSegmentIndex=2;
 [self.sendLanguage addTarget:self action:@selector(changeDraftLanguage) forControlEvents:UIControlEventValueChanged];
 [self.draftTranslator setTargetLanguage:@"zh-Hans"];
 self.translateButton=[UIButton buttonWithType:UIButtonTypeSystem];
 [self.translateButton setTitle:@"초안 번역" forState:UIControlStateNormal];
 [self.translateButton addTarget:self action:@selector(translateDraft) forControlEvents:UIControlEventTouchUpInside];
 self.translateButton.translatesAutoresizingMaskIntoConstraints=NO;
 self.sendButton=[UIButton buttonWithType:UIButtonTypeSystem];
 [self.sendButton setTitle:@"전송" forState:UIControlStateNormal];
 [self.sendButton addTarget:self action:@selector(confirmSend) forControlEvents:UIControlEventTouchUpInside];
 self.sendButton.translatesAutoresizingMaskIntoConstraints=NO;
 self.attachButton=[UIButton buttonWithType:UIButtonTypeSystem];
 [self.attachButton setTitle:@"＋" forState:UIControlStateNormal];
 self.attachButton.titleLabel.font=[UIFont boldSystemFontOfSize:22];
 [self.attachButton addTarget:self action:@selector(chooseAttachment) forControlEvents:UIControlEventTouchUpInside];
 self.attachButton.translatesAutoresizingMaskIntoConstraints=NO;
 self.previewLabel=[UITextView new];self.previewLabel.text=@"";
 self.previewLabel.font=[UIFont systemFontOfSize:15];
 self.previewLabel.textColor=UIColor.labelColor;
 self.previewLabel.backgroundColor=UIColor.whiteColor;
 self.previewLabel.layer.cornerRadius=8;
 self.previewLabel.layer.borderWidth=0.5;
 self.previewLabel.layer.borderColor=UIColor.separatorColor.CGColor;
 self.previewLabel.editable=YES;
 self.previewLabel.delegate=self;
 self.previewLabel.translatesAutoresizingMaskIntoConstraints=NO;
 UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisHorizontal;actions.spacing=6;
 actions.alignment=UIStackViewAlignmentCenter;actions.distribution=UIStackViewDistributionFill;
 actions.translatesAutoresizingMaskIntoConstraints=NO;
 [actions addArrangedSubview:self.sendLanguage];
 [actions addArrangedSubview:self.translateButton];
 [actions addArrangedSubview:self.attachButton];
 [actions addArrangedSubview:self.sendButton];
 for (UIView *v in @[draftLabel,self.composer,self.previewLabel,actions]) [self.composerArea addSubview:v];
 [NSLayoutConstraint activateConstraints:@[
 [languageBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
 [languageBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
 [languageBar.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-12],
 [languageBar.heightAnchor constraintEqualToConstant:32],
 [self.table.topAnchor constraintEqualToAnchor:languageBar.bottomAnchor constant:6],
 [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
 [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
 [self.table.bottomAnchor constraintEqualToAnchor:self.composerArea.topAnchor],
 [self.composerArea.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
 [self.composerArea.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
 [self.composerArea.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
 [draftLabel.topAnchor constraintEqualToAnchor:self.composerArea.topAnchor constant:8],
 [draftLabel.leadingAnchor constraintEqualToAnchor:self.composerArea.leadingAnchor constant:12],
 [self.composer.topAnchor constraintEqualToAnchor:draftLabel.bottomAnchor constant:6],
 [self.composer.leadingAnchor constraintEqualToAnchor:self.composerArea.leadingAnchor constant:12],
 [self.composer.trailingAnchor constraintEqualToAnchor:self.composerArea.trailingAnchor constant:-12],
 [self.composer.heightAnchor constraintEqualToConstant:48],
 [self.previewLabel.topAnchor constraintEqualToAnchor:self.composer.bottomAnchor constant:6],
 [self.previewLabel.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor],
 [self.previewLabel.trailingAnchor constraintEqualToAnchor:self.composer.trailingAnchor],
 [self.previewLabel.heightAnchor constraintEqualToConstant:48],
 [actions.topAnchor constraintEqualToAnchor:self.previewLabel.bottomAnchor constant:6],
 [actions.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor],
 [actions.trailingAnchor constraintEqualToAnchor:self.composer.trailingAnchor],
 [actions.bottomAnchor constraintEqualToAnchor:self.composerArea.bottomAnchor constant:-8],
 [actions.heightAnchor constraintEqualToConstant:34],
 [self.translateButton.widthAnchor constraintEqualToConstant:74],
 [self.sendButton.widthAnchor constraintEqualToConstant:40],
 [self.attachButton.widthAnchor constraintEqualToConstant:30]]];
 [self requestTranslations];
 if (!self.messages.count) {
  UILabel *empty=[UILabel new];empty.text=@"표시할 메시지가 없습니다.";
  empty.textAlignment=NSTextAlignmentCenter;empty.textColor=UIColor.secondaryLabelColor;
  self.table.backgroundView=empty;
 }
}
- (void)viewDidAppear:(BOOL)animated {
 [super viewDidAppear:animated];
 // Dynamic bubble heights and the keyboard layout guide may not settle
 // until the next layout pass, so scroll after the first rendered layout.
 dispatch_async(dispatch_get_main_queue(), ^{
  [self scrollToLatestMessage:NO];
  // Self-sizing cells are finalized after the first table layout pass.
  dispatch_async(dispatch_get_main_queue(), ^{
   [self scrollToLatestMessage:NO];
  });
 });
}
- (BOOL)isViewingLatestMessage {
 if (!self.table || self.messages.count==0) return YES;
 CGFloat bottom=self.table.contentSize.height-self.table.bounds.size.height+self.table.adjustedContentInset.bottom;
 return self.table.contentOffset.y>=MAX(-self.table.adjustedContentInset.top,bottom-100);
}
- (void)scrollToLatestMessage:(BOOL)animated {
 if (!self.table || self.messages.count==0) return;
 [self.view layoutIfNeeded];
 [self.table layoutIfNeeded];
 NSIndexPath *latest=[NSIndexPath indexPathForRow:self.messages.count-1 inSection:0];
 [self.table scrollToRowAtIndexPath:latest atScrollPosition:UITableViewScrollPositionBottom animated:animated];
 // Correct for self-sizing rows and adjusted insets after the row is laid out.
 CGFloat bottom=MAX(-self.table.adjustedContentInset.top,
    self.table.contentSize.height-self.table.bounds.size.height+self.table.adjustedContentInset.bottom);
 [self.table setContentOffset:CGPointMake(0,bottom) animated:animated];
 // A second runloop pass is required when translated text changes cell sizes.
 // Do not animate this correction: it must land above the fixed composer.
}
- (NSString *)chosenLanguage:(UISegmentedControl *)picker {
 NSArray *codes=@[@"ko",@"en",@"zh-Hans"];
 NSInteger index=picker.selectedSegmentIndex;
 return index>=0 && index<codes.count ? codes[index] : @"ko";
}
- (void)changeDraftLanguage {
 [self.draftTranslator setTargetLanguage:[self chosenLanguage:self.sendLanguage]];
 self.translationReady=NO;
 self.previewLabel.text=@"";
}
- (void)textViewDidChange:(UITextView *)textView {
 if (textView==self.composer) {
  self.translationReady=NO;
  self.previewLabel.text=@"";
 }
}
- (void)changeReceiveLanguage {
 [self.translator setTargetLanguage:@"ko"];
 [self.translated removeAllObjects];
 [self.translationAttempted removeAllObjects];
 [self.table reloadData];
 [self requestTranslations];
}
- (void)translateDraft {
 NSString *draft=[self.composer.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if (!draft.length) return;
 self.previewLabel.text=@"번역 중…";
 self.translationReady=NO;
 [self.draftTranslator translateText:draft completion:^(NSString *translated,NSString *error) {
  NSString *current=[self.composer.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (![current isEqualToString:draft]) return;
  self.translationReady=translated.length>0;
  self.previewLabel.text=translated.length?translated:@"";
  if (!translated.length) {
   self.navigationItem.prompt=error.length?@"번역에 실패했습니다. 초안을 확인하세요.":@"번역 결과가 없습니다.";
  } else {
   self.navigationItem.prompt=nil;
  }
 }];
}
- (void)requestTranslations {
 if (!self.translator) return;
 NSUInteger limit=MIN(self.messages.count,100);
 for (NSUInteger i=0;i<limit;i++) {
  NSDictionary *item=[self.messages[i] isKindOfClass:NSDictionary.class]?self.messages[i]:nil;
  NSString *original=[item[@"text"] isKindOfClass:NSString.class]?item[@"text"]:nil;
  // Cached translations must not consume Apple Translation sessions again.
  if (original.length && self.translated[original].length) continue;
  if (!original.length || [original hasPrefix:@"["] ||
      ([original rangeOfString:@"[가-힣]" options:NSRegularExpressionSearch].location!=NSNotFound) ||
      [self.translationAttempted containsObject:original]) continue;
  [self.translationAttempted addObject:original];
  __weak typeof(self) weakSelf=self;
  [self.translator translateText:original completion:^(NSString *translated, NSString *error) {
   typeof(self) strongSelf=weakSelf;
   if (!strongSelf) return;
   if (translated.length && ![translated isEqualToString:original]) {
    strongSelf.translated[original]=translated;
    WXSaveTranslation(original,translated);
   } else if (error.length) {
    strongSelf.translated[original]=@"번역 실패 · 언어팩/지원 언어 확인";
   } else {
    return;
   }
   // A translation changes the height of its message bubble. Keep the view
   // pinned to the newest message only if the user was already near bottom.
   BOOL shouldFollow=[strongSelf isViewingLatestMessage];
   [strongSelf.table reloadData];
   if (shouldFollow) {
    dispatch_async(dispatch_get_main_queue(), ^{
     [strongSelf scrollToLatestMessage:NO];
     dispatch_async(dispatch_get_main_queue(), ^{
      if ([strongSelf isViewingLatestMessage]) [strongSelf scrollToLatestMessage:NO];
     });
    });
   }
  }];
 }
}


- (void)openMembers {
 NSString *peer=self.chat[@"title"];
 if (![peer hasSuffix:@"@chatroom"]) return;
 self.navigationItem.prompt=@"그룹 멤버 불러오는 중…";
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
  int result=wechat_ios_fetch_room_members(peer.UTF8String);
  NSDictionary *obj=nil;
  if (result==0) {
   NSData *raw=[NSData dataWithContentsOfFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"wechat-ios-selected-room-members.json"]];
   id parsed=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil]:nil;
   if ([parsed isKindOfClass:NSDictionary.class]) obj=parsed;
  }
  NSDictionary *reply=obj;
  dispatch_async(dispatch_get_main_queue(), ^{
   if (![reply[@"room"] isEqualToString:peer]) { self.navigationItem.prompt=@"그룹 멤버 조회 실패"; return; }
   NSArray *members=[reply[@"members"] isKindOfClass:NSArray.class]?reply[@"members"]:@[];
   self.roomMembers=members; self.navigationItem.prompt=nil;
   __weak typeof(self) weakSelf=self;
   WXGroupInfoController *info=[[WXGroupInfoController alloc]
      initWithPeer:peer name:WXDisplayName(peer,self.directory) members:members
      selection:^(NSDictionary *member) {
       typeof(self) strongSelf=weakSelf;
       if (!strongSelf) return;
       NSString *name=[member[@"name"] isKindOfClass:NSString.class]?member[@"name"]:@"";
       if (!name.length) return;
       NSString *draft=strongSelf.composer.text?:@"";
       NSString *gap=draft.length && ![draft hasSuffix:@" "]?@" ":@"";
       strongSelf.composer.text=[NSString stringWithFormat:@"%@%@@%@ ",draft,gap,name];
       [strongSelf textViewDidChange:strongSelf.composer];
       [strongSelf.composer becomeFirstResponder];
      }];
   [self.navigationController pushViewController:info animated:YES];
  });
 });
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
 [tableView deselectRowAtIndexPath:indexPath animated:YES];
 if (indexPath.row>=self.messages.count) return;
 NSDictionary *item=self.messages[indexPath.row];
 UIAlertController *action=[UIAlertController alertControllerWithTitle:@"메시지 관리"
 message:[item[@"outgoing"] boolValue]?
 @"삭제는 개발 앱에서만 적용됩니다. 방금 보낸 텍스트 메시지 중 서버 확인 ID가 있는 경우에만 회수를 시도할 수 있습니다.":
 @"이 개발 앱에서만 메시지를 숨깁니다. 상대방 메시지는 삭제되지 않습니다."
 preferredStyle:UIAlertControllerStyleActionSheet];
 [action addAction:[UIAlertAction actionWithTitle:@"이 앱에서 삭제" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
  NSString *peer=self.chat[@"title"];
  if (!WXHideMessage(peer,item)) {self.navigationItem.prompt=@"삭제 기록 저장 실패";return;}
  for (NSDictionary *chat in WXLoadMergedChats()) {
   if ([chat[@"title"] isEqualToString:peer]) { [self updateChat:chat]; break; }
  }
 }]];

 NSString *serverID=[item[@"server_id"] isKindOfClass:NSString.class]?item[@"server_id"]:nil;
 NSNumber *localID=[item[@"send_local_id"] isKindOfClass:NSNumber.class]?item[@"send_local_id"]:nil;
 NSNumber *created=[item[@"created_at"] isKindOfClass:NSNumber.class]?item[@"created_at"]:nil;
 NSTimeInterval age=created?NSDate.date.timeIntervalSince1970-created.doubleValue:DBL_MAX;
 if ([item[@"outgoing"] boolValue] && serverID.length && localID.unsignedIntValue>0 &&
     age>=0 && age<=120) {
  [action addAction:[UIAlertAction actionWithTitle:@"전송 취소 (서버 회수)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
   UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"메시지 회수"
    message:@"WeChat 서버에 이 메시지의 회수를 한 번만 요청합니다. 실패하거나 결과가 불확실하면 자동 재시도하지 않습니다."
    preferredStyle:UIAlertControllerStyleAlert];
   [confirm addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
   [confirm addAction:[UIAlertAction actionWithTitle:@"회수 요청" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    NSString *peer=self.chat[@"title"];
    self.navigationItem.prompt=@"서버 회수 요청 중…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
     int code=wechat_ios_recall_sent_text(peer.UTF8String,serverID.UTF8String,localID.unsignedIntValue,created.unsignedIntValue);
     dispatch_async(dispatch_get_main_queue(), ^{
      if (code==0) {
       WXMarkServerRecalled(serverID);
       for (NSDictionary *chat in WXLoadMergedChats()) {
        if ([chat[@"title"] isEqualToString:peer]) { [self updateChat:chat];break; }
       }
       self.navigationItem.prompt=@"서버가 회수 요청을 수락했습니다";
      } else {
       self.navigationItem.prompt=code==1?@"서버가 회수를 거절했습니다":@"회수 결과 불확실 · 재시도하지 않음";
      }
     });
    });
   }]];
   [self presentViewController:confirm animated:YES completion:nil];
  }]];
 }
 [action addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
 action.popoverPresentationController.sourceView=self.view;
 action.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,self.view.bounds.size.height/2,1,1);
 [self presentViewController:action animated:YES completion:nil];
}
- (void)chooseAttachment {
 if (self.mediaBusy) return;
 UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"사진·파일 전송"
 message:@"선택 후 내용을 확인하고 전송할 수 있습니다. 파일은 현재 20MB 이하만 지원합니다."
 preferredStyle:UIAlertControllerStyleActionSheet];
 [menu addAction:[UIAlertAction actionWithTitle:@"사진 보관함" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
  UIImagePickerController *picker=[UIImagePickerController new];
  picker.sourceType=UIImagePickerControllerSourceTypePhotoLibrary;
  picker.delegate=self;picker.allowsEditing=NO;
  [self presentViewController:picker animated:YES completion:nil];
 }]];
 [menu addAction:[UIAlertAction actionWithTitle:@"파일 선택" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
  UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
  picker.delegate=self;picker.allowsMultipleSelection=NO;
  [self presentViewController:picker animated:YES completion:nil];
 }]];
 [menu addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
 menu.popoverPresentationController.sourceView=self.attachButton;
 menu.popoverPresentationController.sourceRect=self.attachButton.bounds;
 [self presentViewController:menu animated:YES completion:nil];
}
- (NSData *)jpegBytes:(UIImage *)image maximum:(CGFloat)maxSide quality:(CGFloat)quality {
 if (!image || image.size.width<1 || image.size.height<1) return nil;
 CGFloat scale=MIN(1.,maxSide/MAX(image.size.width,image.size.height));
 CGSize target=CGSizeMake(MAX(1,round(image.size.width*scale)),MAX(1,round(image.size.height*scale)));
 UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:target];
 UIImage *normalized=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
   [image drawInRect:CGRectMake(0,0,target.width,target.height)];
 }];
 return UIImageJPEGRepresentation(normalized,quality);
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
 [picker dismissViewControllerAnimated:YES completion:nil];
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
 UIImage *image=info[UIImagePickerControllerOriginalImage];
 [picker dismissViewControllerAnimated:YES completion:nil];
 if (!image) return;
 NSData *original=[self jpegBytes:image maximum:2400 quality:.8];
 NSData *standard=[self jpegBytes:image maximum:1100 quality:.72];
 NSData *thumb=[self jpegBytes:image maximum:180 quality:.55];
 if (!original || !standard || !thumb || original.length>20*1024*1024) {
  self.navigationItem.prompt=@"사진 변환 실패 또는 20MB 초과"; return;
 }
 NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString *o=[base stringByAppendingString:@"-photo.jpg"];
 NSString *m=[base stringByAppendingString:@"-standard.jpg"];
 NSString *t=[base stringByAppendingString:@"-thumb.jpg"];
 if (![original writeToFile:o atomically:YES] || ![standard writeToFile:m atomically:YES] ||
     ![thumb writeToFile:t atomically:YES]) {self.navigationItem.prompt=@"사진 파일 저장 실패";return;}
 [self confirmMediaUploadAt:o standard:m thumbnail:t name:@"photo.jpg" image:YES];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
 NSURL *url=urls.firstObject; if (!url) return;
 NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
 if (!size || size.unsignedLongLongValue==0 || size.unsignedLongLongValue>20*1024*1024) {
  self.navigationItem.prompt=@"파일은 20MB 이하만 지원합니다";return;
 }
 BOOL scoped=[url startAccessingSecurityScopedResource];
 NSString *name=url.lastPathComponent?:@"attachment";
 NSString *dest=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:name.pathExtension?:@"bin"]];
 BOOL ok=[[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil];
 if (scoped) [url stopAccessingSecurityScopedResource];
 if (!ok) {self.navigationItem.prompt=@"파일 선택 오류";return;}
 [self confirmMediaUploadAt:dest standard:nil thumbnail:nil name:name image:NO];
}
- (void)confirmMediaUploadAt:(NSString *)original standard:(NSString *)standard thumbnail:(NSString *)thumb
 name:(NSString *)name image:(BOOL)isImage {
 NSString *peer=[self.chat[@"title"] isKindOfClass:NSString.class]?self.chat[@"title"]:@"";
 if (!peer.length || self.mediaBusy) return;
 UIAlertController *confirm=[UIAlertController alertControllerWithTitle:isImage?@"사진 전송":@"파일 전송"
 message:[NSString stringWithFormat:@"%@에게 %@을(를) 보내시겠습니까?",
 WXDisplayName(peer,self.directory),name] preferredStyle:UIAlertControllerStyleAlert];
 [confirm addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
  for (NSString *path in @[original?:@"",standard?:@"",thumb?:@""]) if (path.length) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
 }]];
 [confirm addAction:[UIAlertAction actionWithTitle:@"전송" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
  self.mediaBusy=YES;self.attachButton.enabled=NO;self.navigationItem.prompt=@"미디어 업로드 중…";
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
   int result=wechat_ios_send_media_file(peer.UTF8String,original.UTF8String,
     standard.UTF8String,thumb.UTF8String,name.UTF8String,isImage?1:0);
   for (NSString *path in @[original?:@"",standard?:@"",thumb?:@""]) if (path.length) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
   dispatch_async(dispatch_get_main_queue(), ^{
    self.mediaBusy=NO;self.attachButton.enabled=YES;
    if (result==0) {
     WXAcceptedOutgoingSave(peer,[NSString stringWithFormat:isImage?@"[사진 전송]":@"[파일 전송] %@",name]);
     for (NSDictionary *chat in WXLoadMergedChats()) {
      if ([chat[@"title"] isEqualToString:peer]) { [self updateChat:chat];break; }
     }
     self.navigationItem.prompt=@"WeChat 서버 접수 확인";
    } else {
     if (result==1) {
      self.navigationItem.prompt=@"WeChat 서버가 미디어 전송을 거절했습니다";
     } else {
      NSString *diagnostic=[NSString stringWithContentsOfFile:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"wechat-ios-media-status.txt"]
        encoding:NSUTF8StringEncoding error:nil];
      NSString *stage=@"전송 과정";
      if ([diagnostic containsString:@"CDN_BOOTSTRAP"]) stage=@"CDN 접속";
      else if ([diagnostic containsString:@"CDN_UPLOAD"]) stage=@"CDN 업로드";
      else if ([diagnostic containsString:@"FILE_PREPARE"]) stage=@"파일 암호화 준비";
      else if ([diagnostic containsString:@"FILE_SUBMIT"]) stage=@"WeChat 메시지 등록";
      else if ([diagnostic containsString:@"READ_FILE"]) stage=@"파일 읽기";
      self.navigationItem.prompt=[NSString stringWithFormat:@"%@ 실패/불확실 · 자동 재전송 없음",stage];
     }
    }
   });
  });
 }]];
 [self presentViewController:confirm animated:YES completion:nil];
}
- (void)confirmSend {
 NSString *recipient=[self.chat[@"title"] isKindOfClass:NSString.class]?self.chat[@"title"]:@"";
 NSString *original=[self.composer.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSString *editedTranslation=[self.previewLabel.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSString *message=(self.translationReady && editedTranslation.length)?editedTranslation:original;
 if (!recipient.length || !message.length || !self.sendButton.enabled) return;
 self.sendButton.enabled=NO;
 self.translateButton.enabled=NO;
 [self.composer resignFirstResponder];
 [self.previewLabel resignFirstResponder];
 NSString *sentOriginal=[original copy];
 NSString *sentTranslation=[editedTranslation copy];
 BOOL wasTranslated=self.translationReady && editedTranslation.length;
 self.navigationItem.prompt=@"전송 중…";
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
  int result=wechat_ios_send_text(recipient.UTF8String,message.UTF8String);
  dispatch_async(dispatch_get_main_queue(), ^{
   self.sendButton.enabled=YES;
   self.translateButton.enabled=YES;
   if (result==0) {
    NSDictionary *receipt=WXLastTextReceipt(recipient,message);
    BOOL saved=WXAcceptedOutgoingSaveWithReceipt(recipient,message,receipt);
    if (saved) {
     for (NSDictionary *chat in WXLoadMergedChats()) {
      if ([chat[@"title"] isEqualToString:recipient]) {
       [self updateChat:chat]; break;
      }
     }
    }
    // Only clear fields if the user did not edit them during submission.
    if ([self.composer.text isEqualToString:sentOriginal] &&
        (!wasTranslated || [self.previewLabel.text isEqualToString:sentTranslation])) {
     self.composer.text=@"";
     self.previewLabel.text=@"";
     self.translationReady=NO;
    }
    self.navigationItem.prompt=saved?@"서버 접수 · 대화에 표시":@"서버 접수 · 기록 저장 오류";
   } else if (result==1) {
    self.navigationItem.prompt=@"서버 수락을 확인하지 못했습니다. 내용 유지";
   } else {
    self.navigationItem.prompt=@"전송 여부 불확실 · 자동 재전송 안 함";
   }
  });
 });
}
- (void)updateChat:(NSDictionary *)chat {
 if (![chat isKindOfClass:NSDictionary.class]) return;
 self.chat=chat;
 self.directory=WXLoadDirectory();
 self.title=WXDisplayName(self.chat[@"title"],self.directory);
 BOOL followLatest=[self isViewingLatestMessage];
 NSUInteger previousCount=self.messages.count;
 self.messages=WXVisibleTextMessages(chat[@"messages"]);
 if (self.isViewLoaded) {
  self.table.backgroundView=nil;
  if (!self.messages.count) {
   UILabel *empty=[UILabel new]; empty.text=@"No synchronized messages yet.";
   empty.textAlignment=NSTextAlignmentCenter; empty.textColor=UIColor.secondaryLabelColor;
   self.table.backgroundView=empty;
  }
  [self.table reloadData];
  if (followLatest || previousCount==0) {
   dispatch_async(dispatch_get_main_queue(), ^{
    [self scrollToLatestMessage:NO];
   });
  }
  [self requestTranslations];
 }
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.messages.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)i {
 UITableViewCell *cell=[t dequeueReusableCellWithIdentifier:@"message"];
 if (!cell) {
  cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"message"];
  cell.selectionStyle=UITableViewCellSelectionStyleNone;
  cell.backgroundColor=UIColor.clearColor;
 }
 for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
 NSDictionary *item=[self.messages[i.row] isKindOfClass:NSDictionary.class]?self.messages[i.row]:@{};
 NSString *original=[item[@"text"] isKindOfClass:NSString.class]?item[@"text"]:@"";
 BOOL outgoing=[item[@"outgoing"] boolValue];
 NSString *name=[item[@"sender"] isKindOfClass:NSString.class]?item[@"sender"]:@"";
 NSString *translation=self.translated[original];
 UIStackView *bubble=[UIStackView new]; bubble.axis=UILayoutConstraintAxisVertical;
 bubble.alignment=UIStackViewAlignmentLeading;bubble.spacing=6;
 bubble.translatesAutoresizingMaskIntoConstraints=NO;
 bubble.layoutMargins=UIEdgeInsetsMake(10,12,10,12);
 bubble.layoutMarginsRelativeArrangement=YES;
 bubble.backgroundColor=outgoing?WXMessageGreen():UIColor.whiteColor;
 bubble.layer.cornerRadius=12;
 if (!outgoing && [self.chat[@"title"] hasSuffix:@"@chatroom"] && name.length) {
   UILabel *sender=[UILabel new];sender.text=name;sender.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
   sender.textColor=UIColor.secondaryLabelColor;sender.numberOfLines=1;[bubble addArrangedSubview:sender];
 }
 NSString *shownText=original;
 UILabel *body=[UILabel new];body.text=shownText;body.numberOfLines=0;body.font=[UIFont systemFontOfSize:16];
 [bubble addArrangedSubview:body];
 if (translation.length) {
   UIView *line=[UIView new];line.backgroundColor=UIColor.separatorColor;
   [bubble addArrangedSubview:line];
   [line.heightAnchor constraintEqualToConstant:0.5].active=YES;
   [line.widthAnchor constraintEqualToAnchor:body.widthAnchor].active=YES;
   UILabel *translated=[UILabel new];translated.text=translation;translated.font=[UIFont systemFontOfSize:15];
   translated.textColor=UIColor.secondaryLabelColor;translated.numberOfLines=0;[bubble addArrangedSubview:translated];
 }
 [cell.contentView addSubview:bubble];
 NSLayoutConstraint *side=outgoing?
  [bubble.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12]:
  [bubble.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12];
 [NSLayoutConstraint activateConstraints:@[
  [bubble.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:5],
  [bubble.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5],
  [bubble.widthAnchor constraintLessThanOrEqualToAnchor:cell.contentView.widthAnchor multiplier:.79],
  [bubble.widthAnchor constraintGreaterThanOrEqualToConstant:60],side]];
 return cell;
}

@end

@interface ProbeScene : UIResponder <UIWindowSceneDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UINavigationController *navigation;
@property(nonatomic,strong) UIViewController *login;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UILabel *details;
@property(nonatomic,strong) UIImageView *qrView;
@property(nonatomic,strong) NSTimer *refreshTimer;
@property(nonatomic,strong) UITableView *chatTable;
@property(nonatomic,strong) NSArray *chats;
@property(nonatomic,strong) NSDictionary *directory;
@property(nonatomic,strong) NSDate *lastDirectoryModification;
@property(nonatomic,strong) NSArray *visibleChats;
@property(nonatomic,strong) UISearchTextField *searchField;
@property(nonatomic,strong) UISegmentedControl *roomFilter;
@property(nonatomic,strong) UILabel *roomCount;
@property(nonatomic,strong) UILabel *connectionLabel;
@property(nonatomic,assign) BOOL openedChats;
@property(nonatomic,strong) NSDate *lastChatModification;
@property(nonatomic,strong) NSDate *lastLocalSentModification;
@property(nonatomic,strong) NSDate *lastCatalogModification;
@property(nonatomic,strong) UIButton *loginOptionsButton;
@end
@implementation ProbeScene
- (NSArray *)loadChats {
 return WXLoadMergedChats();
}
- (void)filterChats {
 NSString *keyword=[self.searchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSInteger filter=self.roomFilter.selectedSegmentIndex;
 NSMutableArray *matches=[NSMutableArray new];
 NSSet *hidden=WXHiddenPeers();
 // '전체 보기' includes reachable contacts WITHOUT claiming they are
 // historical conversations. Discovered threads are always listed first.
 NSMutableArray *combined=[self.chats mutableCopy];
 NSMutableSet *seen=[NSMutableSet new];
 for (NSDictionary *chat in self.chats) {
  NSString *peer=[chat[@"title"] isKindOfClass:NSString.class]?chat[@"title"]:nil;
  if (peer.length) [seen addObject:peer];
 }
 NSString *catalogPath=[NSTemporaryDirectory() stringByAppendingPathComponent:@"wechat-ios-contact-catalog.json"];
 NSData *data=[NSData dataWithContentsOfFile:catalogPath];
 NSDictionary *payload=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
 NSArray *ids=[payload[@"peers"] isKindOfClass:NSArray.class]?payload[@"peers"]:@[];
 NSMutableArray *available=[NSMutableArray new];
 for (NSString *peer in ids) {
  if (![peer isKindOfClass:NSString.class] || peer.length==0 || [seen containsObject:peer]) continue;
  if ([peer hasPrefix:@"gh_"] || [peer hasPrefix:@"@"] || [peer hasPrefix:@"fake_"]) continue;
  NSDictionary *entry=@{@"title":peer,@"preview":@"연락처 · 과거 대화 기록 미수집",
                       @"messages":@[],@"last_timestamp":@0,@"contact_only":@YES};
  [available addObject:entry];
 }
 [available sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
  return [WXDisplayName(a[@"title"],self.directory) localizedStandardCompare:
          WXDisplayName(b[@"title"],self.directory)];
 }];
 [combined addObjectsFromArray:available];
 NSArray *sourceChats=(filter==0)?combined:((filter==1)?self.chats:((filter==3)?available:combined));
 for (NSDictionary *chat in sourceChats) {
  NSString *peer=[chat[@"title"] isKindOfClass:NSString.class]?chat[@"title"]:@"";
  if ([hidden containsObject:peer]) continue;
  NSString *name=WXDisplayName(peer,self.directory);
  NSString *preview=[chat[@"preview"] isKindOfClass:NSString.class]?chat[@"preview"]:@"";
  BOOL group=[peer hasSuffix:@"@chatroom"];
  if (filter==2 && !group) continue;
  if (keyword.length && [name localizedCaseInsensitiveContainsString:keyword]==NO &&
      [preview localizedCaseInsensitiveContainsString:keyword]==NO) continue;
  [matches addObject:chat];
 }
 self.visibleChats=matches;
 if (filter==0) self.roomCount.text=[NSString stringWithFormat:@"%lu개 대화 기록 · %lu개 연락처", (unsigned long)self.chats.count,(unsigned long)available.count];
 else self.roomCount.text=[NSString stringWithFormat:(filter==1)?@"%lu개 최근 대화":(filter==2?@"%lu개 그룹":@"%lu개 연락처"),(unsigned long)matches.count];
 [self.chatTable reloadData];
 self.chatTable.backgroundView=nil;
 if (!matches.count) {
   UILabel *empty=[UILabel new];empty.text=@"표시할 대화가 없습니다.";
   empty.textColor=UIColor.secondaryLabelColor;empty.textAlignment=NSTextAlignmentCenter;
   self.chatTable.backgroundView=empty;
 }
}
- (void)showChats {
 if (self.openedChats) return;
 self.openedChats=YES;
 UIViewController *vc=[UIViewController new]; vc.title=@"WeChat"; vc.view.backgroundColor=WXGrayBackground();
 UIStackView *header=[UIStackView new];header.axis=UILayoutConstraintAxisVertical;header.spacing=10;
 header.translatesAutoresizingMaskIntoConstraints=NO;
 UILabel *heading=[UILabel new];heading.text=@"WeChat PC버전에 로그인했습니다";
 heading.font=[UIFont systemFontOfSize:13];
 heading.textAlignment=NSTextAlignmentCenter;heading.textColor=UIColor.secondaryLabelColor;
 self.roomFilter=[[UISegmentedControl alloc] initWithItems:@[@"전체 보기",@"최근 대화",@"그룹",@"연락처"]];
 self.roomFilter.selectedSegmentIndex=0;
 [self.roomFilter addTarget:self action:@selector(filterChats) forControlEvents:UIControlEventValueChanged];
 // Keep Mac's All/Personal/Group filter available in the header.
 [header addArrangedSubview:self.roomFilter];
 self.searchField=[UISearchTextField new];
 self.searchField.placeholder=@"대화 검색";
 [self.searchField addTarget:self action:@selector(filterChats) forControlEvents:UIControlEventEditingChanged];
 [header insertArrangedSubview:self.searchField atIndex:0];
 UIStackView *info=[[UIStackView alloc] init]; info.axis=UILayoutConstraintAxisHorizontal; info.spacing=9;
 self.roomCount=[UILabel new];self.roomCount.font=[UIFont systemFontOfSize:13];
 self.roomCount.textColor=UIColor.secondaryLabelColor;
 self.connectionLabel=[UILabel new];self.connectionLabel.text=@"● WeChat 연결됨";
 self.connectionLabel.font=[UIFont systemFontOfSize:12];
 self.connectionLabel.textColor=UIColor.systemGreenColor;
 [info addArrangedSubview:self.roomCount];
 [info addArrangedSubview:[UIView new]];
 [info addArrangedSubview:self.connectionLabel];
 [header addArrangedSubview:heading];
 [header addArrangedSubview:info];
 [vc.view addSubview:header];
 self.chatTable=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
 self.chatTable.backgroundColor=UIColor.whiteColor;
 self.chatTable.rowHeight=76;
 self.chatTable.separatorInset=UIEdgeInsetsMake(0,76,0,0);
 self.chatTable.translatesAutoresizingMaskIntoConstraints=NO;
 self.chatTable.dataSource=self;self.chatTable.delegate=self;
 [vc.view addSubview:self.chatTable];
 [NSLayoutConstraint activateConstraints:@[
  [header.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:10],
  [header.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16],
  [header.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16],
  [self.searchField.heightAnchor constraintEqualToConstant:40],
  [self.chatTable.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
  [self.chatTable.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
  [self.chatTable.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
  [self.chatTable.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor]]];
 self.directory=WXLoadDirectory();
 self.chats=[self loadChats];
 [self filterChats];
 vc.navigationItem.rightBarButtonItems=@[
  [[UIBarButtonItem alloc] initWithTitle:@"복원" style:UIBarButtonItemStylePlain target:self action:@selector(showHiddenChats)],
  [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadChats)]
 ];
 [self.navigation setViewControllers:@[vc] animated:YES];
}
- (void)reloadChats {
 self.directory=WXLoadDirectory();
 self.chats=[self loadChats]; [self filterChats];
 UIViewController *top=self.navigation.topViewController;
 if ([top isKindOfClass:ChatDetailController.class]) {
  ChatDetailController *detail=(ChatDetailController *)top;
  NSString *peer=detail.chat[@"title"];
  for (NSDictionary *chat in self.chats) {
   if ([chat[@"title"] isEqualToString:peer]) { [detail updateChat:chat]; break; }
  }
 }
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.visibleChats.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)i {
 UITableViewCell *cell=[t dequeueReusableCellWithIdentifier:@"wxchat"];
 if (!cell) {
   cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"wxchat"];
   cell.backgroundColor=UIColor.whiteColor;
   cell.selectionStyle=UITableViewCellSelectionStyleDefault;
 }
 for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
 NSDictionary *chat=[self.visibleChats[i.row] isKindOfClass:NSDictionary.class]?self.visibleChats[i.row]:@{};
 NSString *peer=[chat[@"title"] isKindOfClass:NSString.class]?chat[@"title"]:@"";
 NSString *name=WXDisplayName(peer,self.directory);
 NSString *preview=[chat[@"preview"] isKindOfClass:NSString.class]?chat[@"preview"]:@"";
 UIImage *photo=WXAvatar(peer,self.directory);
 if (!photo) {
  if ([peer isEqualToString:@"filehelper"]) photo=[UIImage systemImageNamed:@"folder.fill"];
  else if ([peer hasSuffix:@"@chatroom"]) photo=[UIImage systemImageNamed:@"person.3.fill"];
  else photo=[UIImage systemImageNamed:@"person.crop.circle.fill"];
 }
 UIImageView *avatar=[[UIImageView alloc] initWithImage:WXThumbnail(photo,48)];
 avatar.contentMode=UIViewContentModeScaleAspectFill;
 avatar.layer.cornerRadius=6;avatar.clipsToBounds=YES;
 avatar.tintColor=UIColor.systemGrayColor;
 avatar.translatesAutoresizingMaskIntoConstraints=NO;
 UILabel *title=[UILabel new];title.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
 title.text=name;title.numberOfLines=1;title.translatesAutoresizingMaskIntoConstraints=NO;
 UILabel *subtitle=[UILabel new];subtitle.font=[UIFont systemFontOfSize:14];
 subtitle.textColor=UIColor.secondaryLabelColor;subtitle.text=preview;subtitle.numberOfLines=1;
 subtitle.translatesAutoresizingMaskIntoConstraints=NO;
 UILabel *time=[UILabel new];time.font=[UIFont systemFontOfSize:11];
 time.textColor=UIColor.tertiaryLabelColor;time.textAlignment=NSTextAlignmentRight;
 NSNumber *stamp=[chat[@"last_timestamp"] isKindOfClass:NSNumber.class]?chat[@"last_timestamp"]:nil;
 if (stamp) {
  NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"h:mm a";
  time.text=[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:stamp.doubleValue]];
 }
 time.translatesAutoresizingMaskIntoConstraints=NO;
 for (UIView *v in @[avatar,title,subtitle,time]) [cell.contentView addSubview:v];
 [NSLayoutConstraint activateConstraints:@[
  [avatar.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
  [avatar.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
  [avatar.widthAnchor constraintEqualToConstant:48],[avatar.heightAnchor constraintEqualToConstant:48],
  [title.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:12],
  [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:16],
  [title.trailingAnchor constraintLessThanOrEqualToAnchor:time.leadingAnchor constant:-8],
  [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
  [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
  [subtitle.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-15],
  [time.topAnchor constraintEqualToAnchor:title.topAnchor constant:2],
  [time.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
  [time.widthAnchor constraintEqualToConstant:72]]];
 return cell;
}

- (void)showHiddenChats {
 NSSet *hidden=WXHiddenPeers();
 UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"숨긴 대화 복원"
   message:hidden.count?@"개발 앱 목록에서만 숨긴 대화입니다.":@"숨긴 대화가 없습니다."
   preferredStyle:UIAlertControllerStyleActionSheet];
 NSArray *sorted=[hidden.allObjects sortedArrayUsingSelector:@selector(compare:)];
 for (NSString *peer in sorted) {
  [sheet addAction:[UIAlertAction actionWithTitle:WXDisplayName(peer,self.directory) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
   WXSetHidden(peer,NO); [self reloadChats];
  }]];
 }
 [sheet addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
 sheet.popoverPresentationController.sourceView=self.navigation.topViewController.view;
 sheet.popoverPresentationController.sourceRect=CGRectMake(self.navigation.topViewController.view.bounds.size.width-45,0,40,40);
 [self.navigation.topViewController presentViewController:sheet animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
 if (indexPath.row>=self.visibleChats.count) return nil;
 NSDictionary *chat=self.visibleChats[indexPath.row];
 NSString *peer=[chat[@"title"] isKindOfClass:NSString.class]?chat[@"title"]:nil;
 if (!peer.length) return nil;
 UIContextualAction *deleteAction=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"삭제" handler:^(UIContextualAction *action,UIView *source,void (^completion)(BOOL)) {
  UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"대화방 삭제"
   message:@"이 개발 앱의 목록에서만 숨깁니다. 공식 WeChat의 메시지와 대화방은 삭제되지 않습니다. 상단 '복원'으로 다시 표시할 수 있습니다."
   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a){completion(NO);}]];
  [alert addAction:[UIAlertAction actionWithTitle:@"목록에서 삭제" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
   BOOL ok=WXSetHidden(peer,YES);
   if (ok) [self filterChats];
   completion(ok);
  }]];
  [self.navigation.topViewController presentViewController:alert animated:YES completion:nil];
 }];
 return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)i {
 [t deselectRowAtIndexPath:i animated:YES];
 [self.navigation pushViewController:[[ChatDetailController alloc] initWithChat:self.visibleChats[i.row]] animated:YES];
}
- (void)refreshStatus {
 NSString *tmp=NSTemporaryDirectory();
 if (self.openedChats) {
  NSString *catalogPath=[tmp stringByAppendingPathComponent:@"wechat-ios-contact-catalog.json"];
  NSDate *catalogDate=[[NSFileManager defaultManager] attributesOfItemAtPath:catalogPath error:nil][NSFileModificationDate];
  if (catalogDate && (!self.lastCatalogModification ||
      [catalogDate compare:self.lastCatalogModification]==NSOrderedDescending)) {
   self.lastCatalogModification=catalogDate;
   [self filterChats];
  }
  NSString *sentPath=WXOutgoingPath();
  NSDate *sentModified=[[NSFileManager defaultManager] attributesOfItemAtPath:sentPath error:nil][NSFileModificationDate];
  if (sentModified && (!self.lastLocalSentModification ||
      [sentModified compare:self.lastLocalSentModification]==NSOrderedDescending)) {
   self.lastLocalSentModification=sentModified;
   [self reloadChats];
  }
  NSString *directoryPath=[tmp stringByAppendingPathComponent:@"wechat-ios-directory.json"];
  NSDate *dirModified=[[NSFileManager defaultManager] attributesOfItemAtPath:directoryPath error:nil][NSFileModificationDate];
  if (dirModified && (!self.lastDirectoryModification ||
      [dirModified compare:self.lastDirectoryModification]==NSOrderedDescending)) {
      self.lastDirectoryModification=dirModified;
      [self reloadChats];
  }
  NSString *chatPath=[tmp stringByAppendingPathComponent:@"wechat-ios-chats.json"];
  NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:chatPath error:nil];
  NSDate *modified=attrs[NSFileModificationDate];
  if (modified && (!self.lastChatModification || [modified compare:self.lastChatModification]==NSOrderedDescending)) {
   self.lastChatModification=modified;
   [self reloadChats];
  }
 }
 NSString *status=[NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"wechat-ios-probe-status.txt"] encoding:NSUTF8StringEncoding error:nil];
 if (!status) return;
 if ([status hasPrefix:@"QR_READY"] || [status hasPrefix:@"Pending"] || [status hasPrefix:@"Scanned"]) {
  UIImage *qr=[UIImage imageWithContentsOfFile:[tmp stringByAppendingPathComponent:@"wechat-ios-probe-qr.png"]];
  if (qr) self.qrView.image=qr;
 }
 if ([status hasPrefix:@"SYNC_SUCCESS"]) {
  self.status.text=@"Connected to WeChat"; self.details.text=status; self.qrView.hidden=YES; [self showChats];
 } else if ([status hasPrefix:@"SESSION_RESTORE_ATTEMPT"] || [status hasPrefix:@"SESSION_RESTORED"]) {
  self.status.text=@"Restoring saved session"; self.details.text=@"Using secure iPhone Keychain credentials.";
 } else if ([status hasPrefix:@"SESSION_RESTORE_NEEDS_QR"]) {
  self.status.text=@"Reauthentication required"; self.details.text=@"A new QR approval may be necessary.";
 } else if ([status hasPrefix:@"LIVE_PUSH_RECEIVED"] || [status hasPrefix:@"LIVE_RECONNECTED"]) {
  if (self.openedChats) [self reloadChats];
 } else if ([status hasPrefix:@"LOGIN_SUCCESS"] || [status hasPrefix:@"PUSH_"] || [status hasPrefix:@"SYNC_"]) {
  self.status.text=@"Signing in..."; self.details.text=status;
 } else if ([status hasPrefix:@"APPROVED"]) {
  self.status.text=@"Login approved"; self.details.text=@"Establishing connection...";
 } else if ([status hasPrefix:@"Scanned"]) {
  self.status.text=@"Approve on your iPhone"; self.details.text=status;
 } else if ([status hasPrefix:@"Pending"] || [status hasPrefix:@"QR_READY"]) {
  self.status.text=@"Scan with WeChat"; self.details.text=@"Open WeChat on your iPhone and scan this QR code.";
 } else if ([status hasPrefix:@"FAILED"] || [status hasPrefix:@"EXPIRED"]) {
  self.status.text=@"Connection failed"; self.details.text=status;
 }
}
- (void)openLoginOptions {
 UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"로그인 방식" message:@"현재 QR 승인 및 Keychain 자동 로그인만 실제 서버 통신이 검증되었습니다. 아래 방식은 프로토콜 검증 전이며 비밀번호나 인증번호를 입력받지 않습니다." preferredStyle:UIAlertControllerStyleActionSheet];
 NSArray<NSString *> *methods=@[@"휴대전화 번호 + 비밀번호", @"휴대전화 번호 + SMS 인증", @"WeChat ID + 비밀번호", @"이메일 + 비밀번호", @"음성 인증", @"QQ ID + 비밀번호", @"Facebook 로그인", @"iCloud 패스키"];
 for (NSString *name in methods) {
   [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ · 개발 검증 중",name] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
     UIAlertController *info=[UIAlertController alertControllerWithTitle:name
       message:@"공식 WeChat 앱에서 사용하는 로그인 방식입니다. 현재 네이티브 통신 엔진에는 인증 프로토콜 구현이 없어 이 앱에서 로그인할 수 없습니다. 비밀번호와 SMS 인증번호는 수집하거나 저장하지 않습니다."
       preferredStyle:UIAlertControllerStyleAlert];
     [info addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
     [self.login presentViewController:info animated:YES completion:nil];
   }]];
 }
 [sheet addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
 sheet.popoverPresentationController.sourceView=self.loginOptionsButton;
 sheet.popoverPresentationController.sourceRect=self.loginOptionsButton.bounds;
 [self.login presentViewController:sheet animated:YES completion:nil];
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
 self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
 self.login=[UIViewController new]; self.login.view.backgroundColor=UIColor.systemBackgroundColor;
 self.navigation=[[UINavigationController alloc] initWithRootViewController:self.login];
 self.window.rootViewController=self.navigation; [self.window makeKeyAndVisible];
 UIView *view=self.login.view;
 UILabel *title=[UILabel new]; title.text=@"WeChat Native"; title.font=[UIFont boldSystemFontOfSize:30]; title.textAlignment=NSTextAlignmentCenter;
 self.status=[UILabel new]; self.status.font=[UIFont boldSystemFontOfSize:19]; self.status.textAlignment=NSTextAlignmentCenter; self.status.text=@"Preparing QR code...";
 self.qrView=[UIImageView new]; self.qrView.contentMode=UIViewContentModeScaleAspectFit;
 self.details=[UILabel new]; self.details.numberOfLines=0; self.details.font=[UIFont systemFontOfSize:15]; self.details.textColor=UIColor.secondaryLabelColor; self.details.textAlignment=NSTextAlignmentCenter;
 self.loginOptionsButton=[UIButton buttonWithType:UIButtonTypeSystem];
 [self.loginOptionsButton setTitle:@"다른 로그인 방식 확인" forState:UIControlStateNormal];
 [self.loginOptionsButton addTarget:self action:@selector(openLoginOptions) forControlEvents:UIControlEventTouchUpInside];
 UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.status,self.qrView,self.details,self.loginOptionsButton]];
 stack.axis=UILayoutConstraintAxisVertical; stack.spacing=20; stack.translatesAutoresizingMaskIntoConstraints=NO;
 [view addSubview:stack];
 [NSLayoutConstraint activateConstraints:@[
 [stack.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor constant:24],
 [stack.trailingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor constant:-24],
 [stack.centerYAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.centerYAnchor],
 [self.qrView.heightAnchor constraintEqualToConstant:290],
 [title.heightAnchor constraintEqualToConstant:46],
 [self.status.heightAnchor constraintEqualToConstant:34],
 [self.details.heightAnchor constraintGreaterThanOrEqualToConstant:90],
 [self.loginOptionsButton.heightAnchor constraintEqualToConstant:44]]];
 self.refreshTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer){[self refreshStatus];}];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
  int code=wechat_ios_qr_probe(); NSLog(@"WECHAT_IOS_QR_PROBE_RESULT=%d",code);
  dispatch_async(dispatch_get_main_queue(),^{[self refreshStatus];});
 });
}
@end
@interface ProbeDelegate : UIResponder <UIApplicationDelegate> @end
@implementation ProbeDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
 UISceneConfiguration *config=[[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:session.role]; config.delegateClass=ProbeScene.class; return config;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeDelegate.class)); } }
