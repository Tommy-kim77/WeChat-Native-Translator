//! Connect to WeChat, authenticate, synchronize and submit messages with [`NativeClient`].
//!
//! Most server operations are **methods on [`NativeClient`]**, rather than free
//! functions in this crate's Functions list. [`AccountState`] holds accepted
//! credentials; transfer it once into [`NativeClient::from_account`]. Account
//! operations then share that owner. It is secret data, not an API access token.
//!
//! | Task | Start here |
//! | --- | --- |
//! | QR login | [`NativeClient::start_qr_login`], [`NativeClient::poll_login`], [`NativeClient::complete_login`] |
//! | Receive a sync page | [`NativeClient::sync`], [`wire::decode_add_message`] |
//! | Send text | [`NativeClient::send_text`], [`TextSendResult`] |
//! | Contacts and rooms | [`NativeClient::lookup_contacts`], [`NativeClient::lookup_room`] |
//! | Attachments | [`media`], [`media_send`], [`NativeClient::send_file`] |
//! | Logout and shutdown | [`NativeClient::logout`], [`NativeClient::shutdown`], and `_blocking` forms of both |
//! | Classify a failure | [`ServiceRejected`], [`is_session_rejected`], [`AccountInterrupted`], [`NativeRequestNotSubmitted`] |
//! | Low-level encoding | [`wire`], [`protobuf`] |
//!
//! # Send one text message
//!
//! After an approved login, call the client method with the recipient's exact
//! WeChat username. Persist the task ID, timestamp and intended operation in your
//! application's recovery record before submission. A client ID is not a server
//! guarantee against duplicate sends.
//!
//! ```no_run
//! use wechat_protocol::{wire, NativeClient, TextSendOptions, TextSendResult};
//!
//! async fn send_once(
//!     client: &NativeClient,
//!     recipient: &str,
//!     text: &str,
//!     task_id: &str,
//!     created_at: u32,
//! ) -> anyhow::Result<TextSendResult> {
//!     let client_id = wire::client_message_id(task_id.as_bytes());
//!     anyhow::ensure!(client_id != 0, "Choose another task ID");
//!     client.send_text(recipient, text, TextSendOptions {
//!         created_at,
//!         client_message_id: client_id,
//!         source: None,
//!     }).await
//! }
//! ```
//!
//! The source package includes runnable `qr_login`, `send_text` and `sync_once`
//! examples. They keep credentials in memory and perform no profile writes.
//!
//! # Application responsibilities
//!
//! The crate implements supported wire operations, transport authentication and
//! response decoding. The embedding application owns credential storage, send
//! intents, uncertainty handling, sync recovery and official-profile writeback.
//! An accepted receipt establishes server acceptance, not recipient playback or
//! completed local history. An error after submission must not cause a blind resend.
//!
//! This library does not launch or load the official client. Peer responses pass
//! pinned MMTLS signature and record authentication before business decode.
//! Account-owned requests run blocking transport work on Tokio's blocking pool.
//! Login bootstrap and remaining low-level operations
//! are blocking and require a blocking worker in async applications.
//!
//! # Errors
//!
//! Functions return `anyhow::Error`. Branch on the types it carries rather than
//! on message text:
//!
//! - [`ServiceRejected`] holds the [`Service`] and the non-zero code of a
//!   verified response. [`is_session_rejected`] is true when the account needs
//!   a new login or renewal.
//! - [`AccountInterrupted`] says why the account owner ended a request or a
//!   notification wait: stopped, transferred, or superseded by a renewal.
//! - [`NativeRequestNotSubmitted`] says nothing was handed to transport. An
//!   interruption without it has an unknown outcome.
//!
//! # Blocking embedders
//!
//! Applications that run their own blocking workers need no Tokio runtime:
//! use [`NativeClient::request_blocking`],
//! [`NativeClient::open_push_connection_blocking`],
//! [`NativeClient::renew_session_blocking`], [`NativeClient::logout_blocking`],
//! [`PendingLogout::submit_blocking`] and [`NativeClient::shutdown_blocking`].
pub mod business;

pub mod calls;
mod client;
mod errors;
pub use errors::{is_session_rejected, AccountInterrupted, Service, ServiceRejected};
mod lan_login;
pub use lan_login::login_lan_error_reason;
pub mod contact_sync;
pub mod crypto;
pub mod file_upload;
pub mod media;
pub mod media_send;
pub mod mmtls;
mod notice;
pub mod openim;
pub use openim::{OpenImContact, OpenImServiceError};
pub mod protobuf;
pub mod push;
pub mod quote_send;
pub mod silk;
pub mod wire;
pub use client::*;

pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

mod sticker_id;
pub mod sticker_packs;
pub mod sticker_send;
pub use sticker_id::{StickerId, StickerPackId};
pub mod sticker_upload;

pub mod custom_stickers;


// Only an explicit iOS button-confirmed action calls this bridge.
// A failed/uncertain submission is never retried automatically.
#[cfg(target_os = "ios")]
static IOS_ACCOUNT_FOR_SEND: std::sync::OnceLock<std::sync::Mutex<Option<NativeClient>>> =
    std::sync::OnceLock::new();

#[cfg(target_os = "ios")]
fn ios_active_send_client() -> &'static std::sync::Mutex<Option<NativeClient>> {
    IOS_ACCOUNT_FOR_SEND.get_or_init(|| std::sync::Mutex::new(None))
}

/// Submit a single user-confirmed UTF-8 text message. No automatic send or retry.
/// Returns 0=verified server acceptance, 1=explicit refusal, 2=unknown/error.
#[cfg(target_os = "ios")]
#[no_mangle]
pub unsafe extern "C" fn wechat_ios_send_text(
    destination: *const std::ffi::c_char,
    content: *const std::ffi::c_char,
) -> i32 {
    let status_path = std::env::temp_dir().join("wechat-ios-send-result.txt");
    let report = |status: &str| { let _ = std::fs::write(&status_path, status); };
    report("SENDING");
    let attempt = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> anyhow::Result<bool> {
        use anyhow::{anyhow, ensure};
        use std::ffi::CStr;
        ensure!(!destination.is_null() && !content.is_null(), "Missing send inputs");
        let to = unsafe { CStr::from_ptr(destination) }.to_str()?;
        let msg = unsafe { CStr::from_ptr(content) }.to_str()?;
        ensure!(!to.trim().is_empty() && to.len() <= 256, "Invalid destination");
        ensure!(!msg.trim().is_empty() && msg.len() <= 64 * 1024, "Invalid text");
        let client = ios_active_send_client().lock().map_err(|_| anyhow!("Account lock unavailable"))?
            .as_ref().cloned().ok_or_else(|| anyhow!("Not connected"))?;
        let mut id_bytes = [0u8; 4];
        openssl::rand::rand_bytes(&mut id_bytes)?;
        let mut id = u32::from_le_bytes(id_bytes);
        if id == 0 { id = 1; }
        let opts = TextSendOptions {
            created_at: u32::try_from(wire::unix_time()?)?,
            client_message_id: id,
            source: None,
        };
        let receipt = client.request_blocking(|request| request.send_text(to, msg, &opts))?;
        let accepted=receipt.accepted && receipt.returned_destination_matches &&
            receipt.returned_client_id_matches && receipt.server_message_id.is_some();
        if accepted {
            let server_id=receipt.server_message_id.as_ref().expect("accepted id checked");
            let own=client.account_identity()?.own_username;
            let journal_path=std::env::temp_dir().join("wechat-ios-text-send-receipts.json");
            let mut entries:Vec<serde_json::Value>=std::fs::read(&journal_path).ok()
                .and_then(|data|serde_json::from_slice(&data).ok()).unwrap_or_default();
            let digest=openssl::sha::sha256(msg.as_bytes());
            let digest_hex:String=digest.iter().map(|b|format!("{b:02x}")).collect();
            entries.push(serde_json::json!({
                "peer":to, "own":own, "sha256":digest_hex,
                "server_id":server_id,"local_id":id,
                "created_at":opts.created_at, "recall_attempted":false
            }));
            // Keep bounded and write before exposing receipt to UI.
            if entries.len()>512 {entries.drain(0..entries.len()-512);}
            let staging=journal_path.with_extension("json.new");
            std::fs::write(&staging,serde_json::to_vec(&entries)?)?;
            std::fs::rename(staging,journal_path)?;
            // Only the latest verified outgoing receipt, no message text.
            let last=serde_json::json!({
                "peer":to,"sha256":digest_hex,"server_id":server_id,
                "local_id":id,"created_at":opts.created_at
            });
            let last_path=std::env::temp_dir().join("wechat-ios-last-text-receipt.json");
            std::fs::write(last_path,serde_json::to_vec(&last)?)?;
        }
        Ok(accepted)
    }));
    match attempt {
        Ok(Ok(true)) => { report("ACCEPTED"); 0 }
        Ok(Ok(false)) => { report("REJECTED_OR_UNVERIFIED"); 1 }
        _ => { report("UNCERTAIN_NO_AUTO_RETRY"); 2 }
    }
}


/// Explicit one-tap upload and submit, no automatic retry.
/// 0=server accepted, 1=rejected, 2=uncertain/error. Private media not logged.
#[cfg(target_os = "ios")]
#[no_mangle]
pub unsafe extern "C" fn wechat_ios_send_media_file(
    destination: *const std::ffi::c_char,
    original_path: *const std::ffi::c_char,
    standard_path: *const std::ffi::c_char,
    thumb_path: *const std::ffi::c_char,
    name_ptr: *const std::ffi::c_char,
    image_mode: i32,
) -> i32 {
    use anyhow::{anyhow,ensure};
    use std::ffi::CStr;
    use crate::media::{CdnClient,PreparedUpload,PreparedImageUpload,MediaQuality};
    let status=std::env::temp_dir().join("wechat-ios-media-status.txt");
    let _=std::fs::write(&status,"MEDIA_STAGE_INPUT");
    let mark=|stage:&str| { let _=std::fs::write(&status,stage); };
    let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> anyhow::Result<bool> {
        ensure!(!destination.is_null() && !original_path.is_null() && !name_ptr.is_null(), "Missing upload input");
        let to=unsafe { CStr::from_ptr(destination) }.to_str()?;
        let path=unsafe { CStr::from_ptr(original_path) }.to_str()?;
        let name=unsafe { CStr::from_ptr(name_ptr) }.to_str()?;
        ensure!(!to.is_empty() && to.len()<256 && name.len()<=240 && !name.is_empty(), "Invalid upload metadata");
        mark("MEDIA_STAGE_READ_FILE");
        let raw=std::fs::read(path)?;
        ensure!(!raw.is_empty() && raw.len()<=20*1024*1024,"Upload file exceeds 20 MB pilot limit");
        let account=ios_active_send_client().lock().map_err(|_|anyhow!("Account lock failed"))?
            .as_ref().cloned().ok_or_else(||anyhow!("Not connected"))?;
        mark("MEDIA_STAGE_CDN_BOOTSTRAP");
        let config=account.request_blocking(|req|req.cdn_config())?;
        let cdn=CdnClient::new(config,std::time::Duration::from_secs(40))?;
        let mut randomness=[0u8;16];
        openssl::rand::rand_bytes(&mut randomness)?;
        let client_id=format!("ios{}",randomness.iter().map(|b|format!("{b:02x}")).collect::<String>());
        if image_mode==1 {
            ensure!(!standard_path.is_null()&&!thumb_path.is_null(),"Missing image previews");
            let standard=std::fs::read(unsafe {CStr::from_ptr(standard_path)}.to_str()?)?;
            let thumbnail=std::fs::read(unsafe {CStr::from_ptr(thumb_path)}.to_str()?)?;
            ensure!(standard.len()<=5*1024*1024&&thumbnail.len()<=1024*1024,"Image preview too big");
            mark("MEDIA_STAGE_IMAGE_PREPARE");
            let prepared=PreparedImageUpload::prepare(&raw,&standard,&thumbnail,name,to)?;
            mark("MEDIA_STAGE_IMAGE_CDN_UPLOAD");
            let uploaded=cdn.upload_image(&prepared)?;
            mark("MEDIA_STAGE_IMAGE_SUBMIT");
            let reply=account.request_blocking(|req| req.send_image(to,&client_id,&uploaded))?;
            Ok(matches!(reply.status,crate::media_send::SendStatus::ServerAccepted)
                && reply.server_message_id.is_some())
        } else {
            mark("MEDIA_STAGE_FILE_PREPARE");
            let prepared=PreparedUpload::prepare(&raw,MediaQuality::File,name,to)?;
            mark("MEDIA_STAGE_FILE_CDN_UPLOAD");
            let uploaded=cdn.upload(&prepared)?;
            let timestamp=u32::try_from(wire::unix_time()?)?;
            mark("MEDIA_STAGE_FILE_SUBMIT");
            let reply=account.request_blocking(|req|req.send_file(to,&client_id,timestamp,&uploaded,None))?;
            Ok(matches!(reply.status,crate::media_send::SendStatus::ServerAccepted)
                && reply.server_message_id.is_some())
        }
    }));
    match result {
        Ok(Ok(true)) => {let _=std::fs::write(status,"MEDIA_SERVER_ACCEPTED");0},
        Ok(Ok(false)) => {let _=std::fs::write(status,"MEDIA_REJECTED");1},
        other => {
            let stage=std::fs::read_to_string(&status).unwrap_or_else(|_|"MEDIA_STAGE_UNKNOWN".into());
            // Only diagnostic categories and a sanitized error, never file paths,
            // receiver identifiers, media bytes, cookies, tokens or CDN credentials.
            let reason=match &other {
                Ok(Err(err)) => {
                    let debug=format!("{err:#}").to_lowercase();
                    if debug.contains("file requires multiphase") {"FILE_REQUIRES_MULTIPHASE"}
                    else if debug.contains("unsupported") {"UNSUPPORTED"}
                    else if debug.contains("timeout") || debug.contains("timed out") {"NETWORK_TIMEOUT"}
                    else if debug.contains("rejected") {"SERVICE_REJECTED"}
                    else if debug.contains("invalid") {"INVALID_REQUEST_OR_RESPONSE"}
                    else if debug.contains("credential") || debug.contains("session") {"SESSION_ERROR"}
                    else {"PROTOCOL_OR_NETWORK_ERROR"}
                },
                _ => "PANIC_OR_UNKNOWN"
            };
            let _=std::fs::write(status,format!("MEDIA_UNCERTAIN_NO_RETRY stage={stage} reason={reason}"));
            2
        }
    }
}


#[cfg(target_os = "ios")]
#[no_mangle]
pub unsafe extern "C" fn wechat_ios_fetch_room_members(room: *const std::ffi::c_char) -> i32 {
    use std::ffi::CStr;
    let status=std::env::temp_dir().join("wechat-ios-room-status.txt");
    let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> anyhow::Result<usize> {
        anyhow::ensure!(!room.is_null(),"Room missing");
        let name=unsafe { CStr::from_ptr(room) }.to_str()?;
        anyhow::ensure!(name.ends_with("@chatroom") && name.len()<=256,"Invalid room");
        let account=ios_active_send_client().lock().map_err(|_|anyhow::anyhow!("Account lock"))?
            .as_ref().cloned().ok_or_else(||anyhow::anyhow!("No connected session"))?;
        let roster=account.request_blocking(|req|req.lookup_room(name,0))?;
        let ids:Vec<String>=roster.members.iter().take(80).map(|m|m.username.clone()).collect();
        let mut avatar_files=std::collections::HashMap::<String,String>::new();
        // The user explicitly opened this room. Download small profile pictures only.
        for chunk in ids.chunks(2) {
            if let Ok(pictures)=account.request_blocking(|req|req.download_avatars(chunk)) {
                for picture in pictures {
                    if picture.bytes.is_empty() || picture.bytes.len()>512*1024 {continue;}
                    let png=picture.bytes.starts_with(&[0x89,0x50,0x4e,0x47]);
                    let jpeg=picture.bytes.starts_with(&[0xff,0xd8,0xff]);
                    if !png && !jpeg {continue;}
                    let hash=openssl::sha::sha256(picture.username.as_bytes());
                    let digest:String=hash.iter().map(|b|format!("{b:02x}")).collect();
                    let filename=format!("wechat-ios-avatar-{}.{}",&digest[..20],if png{"png"}else{"jpg"});
                    if std::fs::write(std::env::temp_dir().join(&filename),&picture.bytes).is_ok() {
                        avatar_files.insert(picture.username,filename);
                    }
                }
            }
        }

        // Some accounts return only advertised head-image URLs, not inline bytes.
        // Try contact metadata in the protocol's supported 1-2 ID batches.
        for chunk in ids.chunks(2) {
            let pending:Vec<String>=chunk.iter().filter(|id|!avatar_files.contains_key(*id))
                .cloned().collect();
            if pending.is_empty() {continue;}
            if let Ok(lookup)=account.request_blocking(|req|req.lookup_contacts(&pending)) {
                for contact in lookup.contacts {
                    if avatar_files.contains_key(&contact.username) {continue;}
                    let source=contact.small_avatar_url.as_deref()
                        .or(contact.large_avatar_url.as_deref());
                    let Some(url)=source else {continue;};
                    let Ok(bytes)=crate::media::download_advertised_avatar(url) else {continue;};
                    if bytes.is_empty() || bytes.len()>512*1024 {continue;}
                    let png=bytes.starts_with(&[0x89,0x50,0x4e,0x47]);
                    let jpeg=bytes.starts_with(&[0xff,0xd8,0xff]);
                    if !png && !jpeg {continue;}
                    let hash=openssl::sha::sha256(contact.username.as_bytes());
                    let digest:String=hash.iter().map(|b|format!("{b:02x}")).collect();
                    let filename=format!("wechat-ios-avatar-{}.{}",&digest[..20],if png{"png"}else{"jpg"});
                    if std::fs::write(std::env::temp_dir().join(&filename),bytes).is_ok() {
                        avatar_files.insert(contact.username,filename);
                    }
                }
            }
        }
        let members:Vec<serde_json::Value>=roster.members.iter().map(|m| serde_json::json!({
            "username":m.username,
            "name":m.room_display_name.as_ref().filter(|s|!s.is_empty())
                .or(m.nickname.as_ref().filter(|s|!s.is_empty()))
                .unwrap_or(&m.username),
            "avatar_file":avatar_files.get(&m.username)
        })).collect();
        let output=serde_json::json!({"room":name,"members":members});
        let path=std::env::temp_dir().join("wechat-ios-selected-room-members.json");
        let staging=path.with_extension("json.new");
        std::fs::write(&staging,serde_json::to_vec(&output)?)?;
        std::fs::rename(staging,path)?;
        Ok(members.len())
    }));
    match result {
        Ok(Ok(count)) => {
            let avatars=std::fs::read(std::env::temp_dir().join("wechat-ios-selected-room-members.json")).ok()
                .and_then(|raw|serde_json::from_slice::<serde_json::Value>(&raw).ok())
                .and_then(|v|v["members"].as_array().map(|a|a.iter().filter(|x|x["avatar_file"].as_str().is_some()).count()))
                .unwrap_or(0);
            let _=std::fs::write(status,format!("ROOM_MEMBERS_OK count={count} avatars={avatars}"));0
        },
        _ => {let _=std::fs::write(status,"ROOM_MEMBERS_FAILED");1}
    }
}

/// Recall only an eligible text send for which this app recorded an exact
/// server-accepted receipt. A recall attempt is durably marked *before* RPC.
/// 0=server accepted, 1=explicit refusal or ineligible, 2=uncertain. No retry.
#[cfg(target_os = "ios")]
#[no_mangle]
pub unsafe extern "C" fn wechat_ios_recall_sent_text(
    peer_ptr:*const std::ffi::c_char,
    server_ptr:*const std::ffi::c_char,
    local_id:u32,
    created_at:u32,
) -> i32 {
    use anyhow::{anyhow,ensure};
    use std::ffi::CStr;
    let path=std::env::temp_dir().join("wechat-ios-text-recall-status.txt");
    let _=std::fs::write(&path,"RECALL_START");
    let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> anyhow::Result<bool> {
        ensure!(!peer_ptr.is_null()&&!server_ptr.is_null(),"Missing recall inputs");
        let peer=unsafe {CStr::from_ptr(peer_ptr)}.to_str()?;
        let server=unsafe {CStr::from_ptr(server_ptr)}.to_str()?;
        ensure!(local_id>0 && created_at>0,"Invalid local ID or time");
        let now=u32::try_from(wire::unix_time()?)?;
        ensure!(now>=created_at && now-created_at<=120,"Recall window expired");
        let account=ios_active_send_client().lock().map_err(|_|anyhow!("Account lock failed"))?
            .as_ref().cloned().ok_or_else(||anyhow!("Not authenticated"))?;
        let own=account.account_identity()?.own_username;
        let journal=std::env::temp_dir().join("wechat-ios-text-send-receipts.json");
        let mut entries:Vec<serde_json::Value>=serde_json::from_slice(&std::fs::read(&journal)?)?;
        let entry=entries.iter_mut().find(|r|{
            r["peer"].as_str()==Some(peer) &&
            r["own"].as_str()==Some(own.as_str()) &&
            r["server_id"].as_str()==Some(server) &&
            r["local_id"].as_u64()==Some(local_id as u64) &&
            r["created_at"].as_u64()==Some(created_at as u64)
        }).ok_or_else(||anyhow!("Unverified recall receipt"))?;
        ensure!(entry["recall_attempted"]==false,"Recall already attempted");
        entry["recall_attempted"]=serde_json::json!(true);
        let staging=journal.with_extension("json.new");
        std::fs::write(&staging,serde_json::to_vec(&entries)?)?;
        std::fs::rename(staging,journal)?;
        let request=MessageRecall::for_source(peer.into(),server.into(),local_id,created_at);
        let response=account.request_blocking(|req|req.recall_message(&request))?;
        Ok(response.accepted && response.service_code==0)
    }));
    match result {
        Ok(Ok(true))=>{let _=std::fs::write(path,"RECALL_ACCEPTED");0},
        Ok(Ok(false))=>{let _=std::fs::write(path,"RECALL_REJECTED");1},
        _=>{let _=std::fs::write(path,"RECALL_UNCERTAIN_OR_INELIGIBLE_NO_RETRY");2}
    }
}

// Temporary iOS diagnostic probe: never log QR identifiers, keys, or credentials.
#[no_mangle]
pub extern "C" fn wechat_ios_qr_probe() -> i32 {
    let dir = std::env::temp_dir();
    let status_path = dir.join("wechat-ios-probe-status.txt");
    let log_path = dir.join("wechat-ios-probe-events.log");
    let _ = std::fs::remove_file(&log_path);
    let report = |event: &str| {
        let ts = wire::unix_time().unwrap_or(0);
        let line = format!("{ts} {event}\n");
        let _ = std::fs::write(&status_path, event);
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&log_path) {
            let _ = f.write_all(line.as_bytes());
        }
    };
    report("STARTING");
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> anyhow::Result<()> {
        if let Ok(Some(saved)) = ios_secure_load() {
            report("SESSION_RESTORE_ATTEMPT");
            if let Ok(restored) = NativeClient::from_account(saved, NativeOptions::default()) {
                match restored.renew_session_blocking("iOS network probe") {
                    Ok(()) => {
                        report("SESSION_RESTORED");
                        if ios_secure_save(&restored).is_err() { report("KEYCHAIN_SAVE_UNAVAILABLE"); }
                        return ios_run_live(restored, &dir, &report);
                    }
                    Err(_) => report("SESSION_RESTORE_NEEDS_QR"),
                }
            }
        }
        let client = NativeClient::new(NativeOptions::default())?;
        let device = DeviceProfile::generate("UnifiedPCLinux x86_64".to_string())?;
        let mut attempt = client.start_qr_login(device, "iOS network probe")?;
        std::fs::write(dir.join("wechat-ios-probe-qr.png"), &attempt.qr_png)?;
        report(&format!("QR_READY expires_at={} now={}", attempt.expires_at, wire::unix_time()?));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(245);
        let mut last = String::new();
        while std::time::Instant::now() < deadline {
            let now = wire::unix_time()?;
            if now >= attempt.expires_at {
                report("EXPIRED_LOCAL");
                anyhow::bail!("QR expired before approval");
            }
            match client.poll_login(&mut attempt) {
                Ok(LoginStatus::Approved) => {
                    report("APPROVED");
                    // Diagnostic only: report publicly routable service hostnames,
                    // never authorization tokens, cookies, account IDs or messages.
                    report(&format!("AUTH_ENDPOINTS long={} short={}", attempt.long_host, attempt.short_host));
                    match client.complete_login(&mut attempt) {
                        Ok(account) => {
                            report("LOGIN_SUCCESS");
                            // Read-only authenticated transport test: never send messages or save their contents.
                            let authenticated = NativeClient::from_account(account, NativeOptions::default())?;
                            if ios_secure_save(&authenticated).is_err() { report("KEYCHAIN_SAVE_UNAVAILABLE"); }
                            return ios_run_live(authenticated, &dir, &report);

                        }
                        Err(err) => { report(&format!("LOGIN_COMPLETE_ERROR: {err:#}")); return Err(err); }
                    }
                }
                Ok(status) => {
                    let state = format!("{status:?} remaining={}s", attempt.expires_at.saturating_sub(now));
                    if state != last { report(&state); last = state; }
                    if matches!(status, LoginStatus::Expired | LoginStatus::Cancelled | LoginStatus::Rejected | LoginStatus::Completed) {
                        anyhow::bail!("Login stopped: {status:?}");
                    }
                }
                Err(err) => {
                    if is_retryable_login_poll_error(&err) {
                        report(&format!("POLL_RETRYABLE_ERROR: {err:#}"));
                    } else {
                        report(&format!("POLL_ERROR: {err:#}"));
                        return Err(err);
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        report("TIMEOUT");
        anyhow::bail!("QR login timed out")
    }));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(err)) => { report(&format!("FAILED: {err:#}")); 1 },
        Err(_) => { report("PANIC"); 2 },
    }
}

#[cfg(target_os = "ios")]
unsafe extern "C" {
    fn wechat_keychain_save(bytes: *const u8, len: usize) -> i32;
    fn wechat_keychain_load(bytes: *mut u8, capacity: usize) -> isize;
}
#[cfg(target_os = "ios")]
fn ios_secure_save(client: &NativeClient) -> anyhow::Result<()> {
    use zeroize::Zeroizing;
    let saved = client.export_account_state()?;
    let serialized = Zeroizing::new(serde_json::to_vec(&saved)?);
    let status = unsafe { wechat_keychain_save(serialized.as_ptr(), serialized.len()) };
    anyhow::ensure!(status == 0, "iOS Keychain write error {status}");
    Ok(())
}
#[cfg(target_os = "ios")]
fn ios_secure_load() -> anyhow::Result<Option<AccountState>> {
    use zeroize::Zeroizing;
    let mut buffer = Zeroizing::new(vec![0u8; 8 * 1024 * 1024]);
    let len = unsafe { wechat_keychain_load(buffer.as_mut_ptr(), buffer.len()) };
    if len == -25300 { return Ok(None); } // errSecItemNotFound
    anyhow::ensure!(len > 0 && len as usize <= buffer.len(), "Keychain read unavailable");
    let state: AccountState = serde_json::from_slice(&buffer[..len as usize])?;
    state.validate()?;
    Ok(Some(state))
}

#[cfg(target_os = "ios")]
fn ios_run_live(
    authenticated: NativeClient,
    dir: &std::path::Path,
    report: &impl Fn(&str),
) -> anyhow::Result<()> {
        if let Ok(mut active) = ios_active_send_client().lock() {
            *active = Some(authenticated.clone());
        }
        // Catalog is read-only; keep it off the Push/sync worker to avoid blocking incoming messages.
        let catalog_client = authenticated.clone();
        let catalog_dir = dir.to_path_buf();
        std::thread::spawn(move || {
            let result = ios_fetch_full_contact_catalog(&catalog_client, &catalog_dir);
            let status = match result {
                Ok((count, complete)) => format!("CATALOG_COUNT {count} complete={complete}"),
                Err(err) => format!("CATALOG_ERROR {err:#}")
            };
            let _ = std::fs::write(catalog_dir.join("wechat-ios-catalog-status.txt"), status);
        });
        report("PUSH_CONNECTING");
                            let mut connection = match authenticated.open_push_connection_blocking() {
                                Ok(connection) => { report("PUSH_CONNECTED"); connection }
                                Err(err) => { report(&format!("PUSH_CONNECT_ERROR: {err:#}")); return Err(err); }
                            };
                            report("SYNC_REQUESTING");
                            // Cursor is kept for this live session. Do not replay the initial page
                            // on every push, and do not keep credential/session tokens in UI files.
                            let mut cursor = Vec::<u8>::new();
                            let mut conversations: std::collections::BTreeMap<String, Vec<serde_json::Value>> = std::collections::BTreeMap::new();
                            let mut seen = std::collections::HashSet::<String>::new();
                            let mut last_sync = std::time::Instant::now();
                            let mut reconnects = 0_u32;
                            'live_loop: loop {
                                let mut processed = 0_usize;
                                let mut pages = 0_usize;
                                let mut more = true;
                                while more && pages < 64 {
                                    let batch = match connection.sync(&cursor, 6) {
                                        Ok(batch) => batch,
                                        Err(err) => {
                                            report(&format!("LIVE_SYNC_ERROR: {err:#}"));
                                            // A stale PC push socket may be closed by the server
                                            // when another desktop client logs in. Do not kill
                                            // the whole iOS receive worker on a single broken pipe.
                                            reconnects += 1;
                                            if reconnects > 12 {
                                                report("LIVE_SYNC_RECONNECT_LIMIT");
                                                return Err(err);
                                            }
                                            let delay=std::time::Duration::from_secs(
                                                std::cmp::min(30, 2 * reconnects as u64));
                                            std::thread::sleep(delay);
                                            match authenticated.open_push_connection_blocking() {
                                                Ok(fresh) => {
                                                    connection=fresh;
                                                    report("LIVE_SYNC_RECONNECTED");
                                                    continue 'live_loop;
                                                }
                                                Err(reconnect_error) => {
                                                    report(&format!("LIVE_SYNC_RECONNECT_ERROR: {reconnect_error:#}"));
                                                    // Preserve the last successfully applied
                                                    // cursor; reconnect on the next loop iteration.
                                                    continue 'live_loop;
                                                }
                                            }
                                        }
                                    };
                                    let next_cursor = batch.cursor.clone();
                                    more = batch.continuation && next_cursor != cursor;
                                    // A cursor is advanced only after its messages have been processed.
                                    let own = authenticated.account_identity()?.own_username;
                                    for command in &batch.commands {
                                        if command.id != 5 { continue; }
                                        if let Ok(message) = wire::decode_add_message(&command.payload, &own) {
                                            let text = if message.message_type == 1 {
                                                message.content_text.as_deref().unwrap_or("[Unable to decode text]")
                                            } else { "[Non-text message]" };
                                            let sender = if message.outgoing { "Me".to_string() }
                                                else { message.sender_id.clone().unwrap_or_else(|| message.from.clone()) };
                                            let key = match message.server_message_id.as_deref() {
                                                Some(id) => format!("server:{id}"),
                                                None => format!("fallback:{}:{}:{}:{}:{}",
                                                    message.peer, message.from, message.created_at, message.message_type, text),
                                            };
                                            if seen.insert(key) {
                                                let record = serde_json::json!({
                                                    "text": text, "sender": sender, "outgoing": message.outgoing,
                                                    "timestamp": message.created_at,
                                                    "server_id": message.server_message_id
                                                });
                                                conversations.entry(message.peer).or_default().push(record);
                                                processed += 1;
                                            }
                                        }
                                    }
                                    cursor = next_cursor;
                                    pages += 1;
                                }
                                if processed > 0 || pages == 1 && conversations.is_empty() {
                                    let mut chats: Vec<serde_json::Value> = conversations.iter().map(|(peer, msgs)| {
                                        let mut messages = msgs.clone();
                                        messages.sort_by_key(|v| v["timestamp"].as_u64().unwrap_or(0));
                                        let last = messages.last();
                                        serde_json::json!({
                                            "title": peer,
                                            "preview": last.and_then(|v| v["text"].as_str()).unwrap_or(""),
                                            "last_timestamp": last.and_then(|v| v["timestamp"].as_u64()).unwrap_or(0),
                                            "messages": messages
                                        })
                                    }).collect();
                                    // Preserve all previously discovered rooms and history. A new Sync
                                    // batch is incremental and must NOT replace the full room list.
                                    ios_preserve_discovered_conversations(dir, &mut chats)?;
                                    chats.sort_by_key(|v| std::cmp::Reverse(v["last_timestamp"].as_u64().unwrap_or(0)));
                                    let payload = serde_json::to_vec(&chats)?;
                                    let temp = dir.join("wechat-ios-chats.json.new");
                                    std::fs::write(&temp, payload)?;
                                    std::fs::rename(&temp, dir.join("wechat-ios-chats.json"))?;
                                }
                                report(&format!("SYNC_SUCCESS live=true pages={} new_messages={} conversations={} continuation={}",
                                    pages, processed, conversations.len(), more));
                                if more {
                                    report("LIVE_SYNC_PAGE_LIMIT");
                                }
                                if let Ok(n) = ios_refresh_peer_directory(
                                    &authenticated, dir, &conversations.keys().cloned().collect::<Vec<_>>()
                                ) {
                                    if n > 0 { report(&format!("DIRECTORY_UPDATED entries={n}")); }
                                }
                                last_sync = std::time::Instant::now();
                                reconnects = 0;
                                loop {
                                    match connection.poll(std::time::Duration::from_secs(15)) {
                                        Ok(Some(notification)) => {
                                            if notification.command == 24 {
                                                report("LIVE_PUSH_RECEIVED");
                                                break;
                                            }
                                        }
                                        Ok(None) => {
                                            // Periodic catch-up even when a push notification is missed.
                                            if last_sync.elapsed() >= std::time::Duration::from_secs(60) {
                                                break;
                                            }
                                        }
                                        Err(err) => {
                                            report(&format!("LIVE_CONNECTION_ERROR: {err:#}"));
                                            reconnects += 1;
                                            if reconnects > 3 { return Err(err); }
                                            std::thread::sleep(std::time::Duration::from_secs(2 * reconnects as u64));
                                            match authenticated.open_push_connection_blocking() {
                                                Ok(fresh) => {
                                                    connection=fresh;
                                                    report("LIVE_RECONNECTED");
                                                    break;
                                                }
                                                Err(open_error) => {
                                                    report(&format!("LIVE_RECONNECT_ERROR: {open_error:#}"));
                                                    continue 'live_loop;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
}

#[cfg(target_os = "ios")]
fn ios_preserve_discovered_conversations(
    dir: &std::path::Path, latest: &mut Vec<serde_json::Value>
) -> anyhow::Result<()> {
    let path=dir.join("wechat-ios-chats.json");
    let previous:Vec<serde_json::Value>=std::fs::read(&path).ok()
        .and_then(|bytes|serde_json::from_slice(&bytes).ok()).unwrap_or_default();
    let mut all=std::collections::BTreeMap::<String,Vec<serde_json::Value>>::new();
    for room in previous.iter().chain(latest.iter()) {
        let Some(id)=room["title"].as_str() else {continue;};
        if id.is_empty() || id.len()>512 {continue;}
        let bucket=all.entry(id.to_owned()).or_default();
        if let Some(messages)=room["messages"].as_array() {
            bucket.extend(messages.iter().filter(|m|m.is_object()).cloned());
        }
    }
    latest.clear();
    for (peer, mut messages) in all {
        let mut unique=std::collections::HashSet::<String>::new();
        messages.retain(|msg| {
            let server=msg["server_id"].as_str().filter(|s| !s.is_empty());
            let key=if let Some(id)=server {format!("server:{id}")} else {
                format!("fallback:{}:{}:{}:{}",msg["timestamp"],msg["outgoing"],msg["sender"],msg["text"])
            };
            unique.insert(key)
        });
        messages.sort_by_key(|msg|msg["timestamp"].as_u64().unwrap_or(0));
        // Bounded retention. One entry per discovered peer even if it has no
        // recently synced messages.
        if messages.len()>1000 {messages.drain(0..messages.len()-1000);}
        let last=messages.last();
        latest.push(serde_json::json!({
            "title":peer,
            "messages":messages,
            "last_timestamp":last.and_then(|v|v["timestamp"].as_u64()).unwrap_or(0),
            "preview":last.and_then(|v|v["text"].as_str()).unwrap_or("")
        }));
    }
    Ok(())
}

#[cfg(target_os = "ios")]
fn ios_refresh_peer_directory(account: &NativeClient, dir: &std::path::Path, peers: &[String]) -> anyhow::Result<usize> {
    let path = dir.join("wechat-ios-directory.json");
    let mut known = serde_json::Map::new();
    if let Ok(raw) = std::fs::read(&path) {
        if let Ok(serde_json::Value::Object(map)) = serde_json::from_slice(&raw) { known = map; }
    }
    let mut changed = 0;
    for peer in peers {
        if known.contains_key(peer) || peer.is_empty() { continue; }
        if peer == "filehelper" || peer == "weixin" {
            let name = if peer == "filehelper" { "파일 전송" } else { "WeChat 팀" };
            known.insert(peer.clone(), serde_json::json!({"name":name}));
            changed += 1;
            continue;
        }
        let Ok(lookup) = account.request_blocking(|req| req.lookup_contacts(&[peer.clone()])) else { continue; };
        let Some(record) = lookup.contacts.into_iter().find(|r| &r.username == peer) else { continue; };
        let name = record.remark.as_deref().filter(|s| !s.trim().is_empty())
            .or_else(|| record.nickname.as_deref().filter(|s| !s.trim().is_empty()))
            .unwrap_or(peer);
        let mut entry = serde_json::json!({"name":name});
        if let Ok(avatars) = account.request_blocking(|req| req.download_avatars(&[peer.clone()])) {
            for avatar in avatars {
                if avatar.username != *peer || avatar.bytes.len() > 1024 * 1024 { continue; }
                let png = avatar.bytes.starts_with(&[0x89, 0x50, 0x4e, 0x47]);
                let jpeg = avatar.bytes.starts_with(&[0xff, 0xd8, 0xff]);
                if !png && !jpeg { continue; }
                let digest = openssl::sha::sha256(peer.as_bytes());
                let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
                let filename = format!("wechat-ios-avatar-{}.{}", &hex[..20], if png {"png"} else {"jpg"});
                if std::fs::write(dir.join(&filename), avatar.bytes).is_ok() {
                    entry["avatar_file"] = serde_json::Value::String(filename);
                }
                break;
            }
        }
        known.insert(peer.clone(), entry);
        changed += 1;
    }
    if changed > 0 {
        let bytes = serde_json::to_vec(&known)?;
        let temp = dir.join("wechat-ios-directory.json.new");
        std::fs::write(&temp, bytes)?;
        std::fs::rename(temp, &path)?;
    }
    Ok(changed)
}

/// Read-only contact/group bootstrap from a real authenticated account.
/// This is *not* a server-side ordered recent-conversation list.
#[cfg(target_os = "ios")]
fn ios_fetch_full_contact_catalog(
    account: &NativeClient,
    dir: &std::path::Path,
) -> anyhow::Result<(usize, bool)> {
    use anyhow::ensure;
    let mut contact_seq=0_u32;
    let mut room_seq=0_u32;
    let mut peers=std::collections::BTreeSet::<String>::new();
    let mut complete=false;
    for _page in 0..128 {
        let page=account.request_blocking(|req| req.init_contacts(contact_seq, room_seq))?;
        for peer in page.usernames {
            if peer.len() <= 512 && peers.len() < 20000 { peers.insert(peer); }
        }
        if !page.more { complete=true; break; }
        ensure!(page.contact_sequence != contact_seq || page.room_sequence != room_seq,
            "Contact catalog cursor stalled");
        contact_seq=page.contact_sequence;
        room_seq=page.room_sequence;
    }
    let payload=serde_json::json!({"peers":peers,"complete":complete});
    let path=dir.join("wechat-ios-contact-catalog.json");
    let tmp=dir.join("wechat-ios-contact-catalog.json.new");
    std::fs::write(&tmp,serde_json::to_vec(&payload)?)?;
    std::fs::rename(tmp,path)?;
    Ok((peers.len(),complete))
}
