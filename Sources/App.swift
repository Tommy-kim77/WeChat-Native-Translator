import AppKit
import ImageIO
import NaturalLanguage
import SwiftUI
import Translation

enum RoomFilter: String, CaseIterable, Identifiable {
    case all = "전체", chats = "대화", groups = "그룹", contacts = "연락처"
    var id: String { rawValue }
}

private struct AutomaticTranslation: Hashable {
    let messageID: String
    let text: String
    let source: String?
    let target: String
    let mixed: MixedLanguageText?
}

struct PendingAttachment {
    let file: URL
    let key = UUID().uuidString
    var source: String?
    var job: String?
}

private enum AvatarRequest: Hashable {
    case group(String)
    case person(String, group: String?)

    var roomID: String {
        switch self {
        case .group(let id): id
        case .person(let id, let group): group ?? id
        }
    }
}

@MainActor
final class ChatModel: ObservableObject {
    let backend = Backend()
    @Published var account: Account?
    @Published var ready = false
    @Published var connected = false
    @Published var loggingIn = false
    @Published var qr: NSImage?
    @Published var status = UIMessage("위챗 연결 엔진 시작 중…")
    @Published var rooms: [Room] = []
    @Published var groups: [Room] = []
    @Published var contacts: [Room] = []
    @Published private(set) var avatarImages: [String: NSImage] = [:]
    @Published private(set) var groupAvatarMembers: [String: [String]] = [:]
    @Published private(set) var displayNames: [String: String] = [:]
    @Published private(set) var wechatContactNames: [String: String] = [:]
    @Published private(set) var checkingContactNames: Set<String> = []
    @Published private(set) var contactNameStatus: [String: UIMessage] = [:]
    @Published var directoryStatus: UIMessage?
    @Published var automaticConfig: TranslationSession.Configuration?
    @Published var selection: String?
    @Published var messages: [Message] = []
    @Published private var hiddenMessageIDs: [String: [String]]
    @Published private var confirmedRecalls: Set<String> = []
    @Published private(set) var pendingRecalls: Set<String> = []
    @Published private var quotedMessages: [String: Message] = [:]
    @Published private(set) var lastHiddenMessage: String?
    private var recallKeys: [String: String] = [:]
    var quotedMessage: Message? { selection.flatMap { quotedMessages[$0] } }
    var visibleMessages: [Message] {
        guard let account, let ids = hiddenMessageIDs[account.id], !ids.isEmpty else { return messages }
        let hidden = Set(ids)
        return messages.filter { !hidden.contains($0.id) }
    }
    @Published private(set) var loadingMessages = false
    @Published private(set) var acknowledgedVersions: [String: String] = [:]
    @Published private(set) var composerDraft = MessageDraft() { didSet { if composerDraft != oldValue { previewDraft = nil } } }
    var draft: String { composerDraft.text }
    @Published var sending = false
    @Published private(set) var attachments: [String: PendingAttachment] = [:]
    @Published private(set) var sendingFiles: Set<String> = []
    @Published private(set) var downloading: Set<String> = []
    let systemLanguage: Language
    private let preferences: UserDefaults
    @Published var interfacePreference: Language? {
        didSet { preferences.set(interfacePreference?.rawValue, forKey: "interfaceLanguage") }
    }
    var interfaceLanguage: Language { interfacePreference ?? systemLanguage }
    @Published var received: Language {
        didSet {
            guard received != oldValue else { return }
            preferences.set(received.rawValue, forKey: "receivedLanguage")
            refreshMessageTranslations()
        }
    }
    @Published var outgoing: Language {
        didSet {
            guard outgoing != oldValue else { return }
            preferences.set(outgoing.rawValue, forKey: "outgoingLanguage")
            previewDraft = nil
        }
    }
    @Published var translations: [String: String] = [:]
    @Published private(set) var previewDraft: MessageDraft?
    var preview: String? { previewDraft?.text }
    @Published var config: TranslationSession.Configuration?
    @Published var translating = false
    @Published private(set) var translationProvider: TranslationProvider
    @Published private(set) var hasDeepLKey = false
    @Published private(set) var checkingDeepLKey = false
    @Published private(set) var deepLSettingsStatus: UIMessage?
    private let deepL = DeepLClient()
    let mixedAutomaticApple = AppleTranslationRoute()
    let mixedManualApple = AppleTranslationRoute()
    private var deepLKey: String?
    private var loadedDeepLKey = false
    private var deepLAutoRetryAfter = Date.distantPast
    private var automaticTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private(set) var translationGeneration = 0
    private var work: (id: UUID, draft: MessageDraft, message: String?, room: String, language: Language)?
    private var previewSource: (draft: MessageDraft, room: String, language: Language)?
    private var drafts: [String: MessageDraft] = [:]
    @Published private(set) var groupRosters: [String: [GroupMember]] = [:]
    @Published private(set) var loadingRosters: Set<String> = []
    @Published private(set) var groupInfoStatus: [String: UIMessage] = [:]
    @Published private(set) var invitingToGroup: Set<String> = []
    @Published private(set) var pendingGroupInvites: [String: [String]] = [:]
    private var groupInviteKeys: [String: String] = [:]
    private var rosterCheckedAt: [String: Date] = [:]
    private var messageCache: [String: [Message]] = [:]
    private var cacheOrder: [String] = []
    private var warmingHistory: Task<Void, Never>?
    private var lastRoomSwitch = Date.distantPast
    private var sendKeys: [String: (request: TextSendRequest, key: String)] = [:]
    private var registeredEnglish: [String: String] = [:]
    private var visibleAvatarRooms: Set<String> = []
    private var pendingAvatars: [AvatarRequest] = []
    private var activeAvatars: Set<AvatarRequest> = []
    private var avatarAttempts: [AvatarRequest: Date] = [:]
    private var lastDirectoryRead = Date.distantPast
    private var readingDirectory = false
    private var requestedGroupNames: Set<String> = []
    private var syncingDirectory = false
    private var queuedTranslations: [AutomaticTranslation] = []
    private var inFlightTranslation: AutomaticTranslation?
    private var translationCache: [AutomaticTranslation: String] = [:]
    private var translationRetries: [AutomaticTranslation: Date] = [:]
    private var nextTranslationRetry = Date.distantFuture
    private var activeAutomaticRoute: (source: String?, target: String)?

    init(preferences: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.preferences = preferences
        self.hiddenMessageIDs = preferences.object(forKey: "hiddenMessageIDs") as? [String: [String]] ?? [:]
        let system = Language.preferred(from: preferredLanguages)
        self.systemLanguage = system
        self.interfacePreference = preferences.string(forKey: "interfaceLanguage").flatMap(Language.init(rawValue:))
        self.received = preferences.string(forKey: "receivedLanguage").flatMap(Language.init(rawValue:)) ?? system
        self.outgoing = preferences.string(forKey: "outgoingLanguage").flatMap(Language.init(rawValue:)) ?? .english
        self.translationProvider = preferences.string(forKey: "translationProvider").flatMap(TranslationProvider.init(rawValue:)) ?? .apple
        if translationProvider == .deepL { loadDeepLKey() }
    }

    func loadDeepLKey() {
        guard !loadedDeepLKey else { return }
        do {
            deepLKey = try DeepLKeychain.load()
            hasDeepLKey = deepLKey != nil
            loadedDeepLKey = true
        } catch {
            deepLSettingsStatus = UIMessage(error: error)
        }
    }

    func selectTranslationProvider(_ provider: TranslationProvider) {
        guard provider != translationProvider else { return }
        if provider == .deepL { loadDeepLKey() }
        translationProvider = provider
        preferences.set(provider.rawValue, forKey: "translationProvider")
        status = UIMessage("번역 엔진: %@", provider.title)
        resetTranslationEngine()
    }

    func saveDeepLKey(_ input: String) async -> Bool {
        guard !checkingDeepLKey else { return false }
        checkingDeepLKey = true
        defer { checkingDeepLKey = false }
        do {
            let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
            try await deepL.validateKey(key)
            try DeepLKeychain.save(key)
            deepLKey = key
            loadedDeepLKey = true
            hasDeepLKey = true
            deepLSettingsStatus = UIMessage("DeepL API 키를 확인하고 저장했습니다.")
            if translationProvider == .deepL {
                status = UIMessage("번역 엔진: %@", TranslationProvider.deepL.title)
                resetTranslationEngine()
            }
            return true
        } catch {
            deepLSettingsStatus = UIMessage(error: error)
            return false
        }
    }

    func removeDeepLKey() {
        guard !checkingDeepLKey else { return }
        do {
            try DeepLKeychain.remove()
            deepLKey = nil
            loadedDeepLKey = true
            hasDeepLKey = false
            deepLSettingsStatus = UIMessage("DeepL API 키를 삭제했습니다.")
            if translationProvider == .deepL {
                status = DeepLError.missingKey.displayMessage
                resetTranslationEngine()
            }
        } catch { deepLSettingsStatus = UIMessage(error: error) }
    }

    private func resetTranslationEngine() {
        translationGeneration += 1
        automaticTask?.cancel()
        manualTask?.cancel()
        automaticTask = nil
        manualTask = nil
        activeAutomaticRoute = nil
        inFlightTranslation = nil
        work = nil
        translating = false
        previewDraft = nil
        config = nil
        automaticConfig = nil
        translationCache.removeAll()
        translationRetries.removeAll()
        deepLAutoRetryAfter = .distantPast
        refreshMessageTranslations()
    }

    func listing(_ filter: RoomFilter) -> [Room] {
        switch filter {
        case .chats:
            let names = Dictionary(uniqueKeysWithValues: (groups + contacts).compactMap { room in room.name.map { (room.id, $0) } })
            return rooms.map { room in
                guard let name = displayNames[room.id] ?? wechatContactNames[room.id] ?? names[room.id] else { return room }
                return room.withName(name)
            }
        case .groups: return groups.map(applyDisplayName)
        case .contacts: return contacts.map(applyDisplayName)
        case .all:
            var seen: Set<String> = []
            let combined = (listing(.chats) + listing(.groups) + listing(.contacts)).filter { seen.insert($0.id).inserted }
            return combined.filter { !$0.isGroup || $0.name != nil } + combined.filter { $0.isGroup && $0.name == nil }
        }
    }

    private func applyDisplayName(_ room: Room) -> Room {
        (displayNames[room.id] ?? wechatContactNames[room.id]).map(room.withName) ?? room
    }

    func refreshContactName(_ room: Room) async {
        guard let account, !room.isGroup, checkingContactNames.insert(room.id).inserted else { return }
        defer { checkingContactNames.remove(room.id) }
        do {
            wechatContactNames[room.id] = try await backend.wechatContactName(account.id, id: room.id)
            contactNameStatus[room.id] = nil
        } catch is CancellationError { }
        catch { contactNameStatus[room.id] = UIMessage(error: error, prefix: "위챗 이름 조회 실패 · %@") }
    }

    private func displayNamesURL() throws -> URL {
        try Backend.appDataDirectory().appendingPathComponent("display-names.json")
    }

    func setDisplayName(_ value: String, for room: Room) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = displayNames
        changed[room.id] = name.isEmpty ? nil : String(name.prefix(200))
        do {
            try JSONEncoder().encode(changed).write(to: displayNamesURL(), options: .atomic)
            displayNames = changed
        } catch { status = UIMessage("표시 이름을 저장하지 못했습니다.") }
    }

    func englishSearchAlias(_ room: Room) -> String? {
        let known: [String: String] = ["filehelper": "File Transfer", "weixin": "WeChat Team", "brandsessionholder": "Service Accounts", "notification_messages": "Subscription Accounts"]
        return known[room.id] ?? registeredEnglish[room.id]
    }

    func start() async {
        do {
            try await backend.start()
            if let bytes = try? Data(contentsOf: displayNamesURL()),
               let names = try? JSONDecoder().decode([String: String].self, from: bytes) { displayNames = names }
            account = try await backend.accounts().first
            ready = true
            connected = account?.authenticated == true
            status = UIMessage(connected ? "연결됨" : "개인 위챗 계정으로 로그인하세요.")
        } catch { status = UIMessage(error: error) }
    }

    func login() async {
        guard ready, !loggingIn else { return }
        loggingIn = true
        qr = nil
        status = UIMessage("위챗 로그인 QR 요청 중…")
        defer { loggingIn = false; qr = nil }
        var active: (String, String)?
        do {
            if account == nil { account = try await backend.newAccount() }
            guard let account else { throw ConnectionError.invalidResponse }
            let operation = try await backend.login(account.id)
            active = (account.id, operation.id)
            var generation = 0
            for _ in 0..<200 {
                try Task.checkCancellation()
                let current = try await backend.operation(account.id, operation.id)
                switch current.state {
                case "succeeded":
                    connected = true
                    status = UIMessage("연결됨 · 대화 목록 불러오는 중…")
                    return
                case "failed", "expired", "rejected", "cancelled", "needs_login":
                    let reason = current.result?.reason ?? current.result?.errorCode ?? current.state
                    status = UIMessage("로그인 미완료 · %@", reason)
                    return
                case "awaiting_approval": status = UIMessage("휴대폰 위챗에서 로그인을 승인해 주세요.")
                default: break
                }
                let next = current.result?.qrGeneration ?? 1
                if current.result?.qrAvailable == true, next != generation {
                    do {
                        qr = NSImage(data: try await backend.qr(account.id, operation.id, generation: next))
                        generation = next
                        if current.state != "awaiting_approval" { status = UIMessage("휴대폰 위챗으로 이 QR을 스캔하세요.") }
                    } catch ConnectionError.response(let code, _) where code == 404 || code == 409 { }
                }
                try await Task.sleep(for: .milliseconds(750))
            }
            status = UIMessage("QR 로그인 시간이 지났습니다. 다시 로그인해 주세요.")
        } catch is CancellationError { status = UIMessage("로그인 취소됨") }
        catch { status = UIMessage(error: error) }
        if let (accountID, operationID) = active { await backend.cancelLogin(accountID, operationID) }
    }

    func poll() async {
        while !Task.isCancelled {
            if ready, !connected, !loggingIn, let current = account,
               let updated = try? await backend.accounts().first(where: { $0.id == current.id }), updated.authenticated == true {
                account = updated
                connected = true
                status = UIMessage("연결됨 · 대화 목록 불러오는 중…")
            }
            if connected, let account {
                do {
                    let newRooms = try await backend.rooms(account.id)
                    if rooms != newRooms { rooms = newRooms }
                    if status.key == "연결됨 · 대화 목록 불러오는 중…" { status = UIMessage("연결됨") }
                    if Date().timeIntervalSince(lastDirectoryRead) >= 45 {
                        Task { await refreshDirectory() }
                    }
                    warmRecentHistory(account.id)
                } catch is CancellationError { return }
                catch { status = UIMessage(error: error) }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func rememberMessages(_ latest: [Message], in room: String) {
        for message in latest where message.isRecalled { confirmedRecalls.insert(message.id) }
        messageCache[room] = latest
        cacheOrder.removeAll { $0 == room }
        cacheOrder.append(room)
        if cacheOrder.count > 50 { messageCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    private func warmRecentHistory(_ account: String) {
        guard warmingHistory == nil, Date().timeIntervalSince(lastRoomSwitch) >= 5 else { return }
        let targets = rooms.prefix(6).filter { $0.id != selection && messageCache[$0.id] == nil }
        guard !targets.isEmpty else { return }
        warmingHistory = Task {
            defer { warmingHistory = nil }
            for room in targets {
                guard !Task.isCancelled else { return }
                if let recent = try? await backend.messages(account, room.id), !Task.isCancelled, selection != room.id {
                    rememberMessages(recent, in: room.id)
                }
            }
        }
    }

    func unreadCount(for room: Room) -> Int {
        if let version = room.readStateVersion, acknowledgedVersions[room.id] == version { return 0 }
        return room.unreadCount ?? 0
    }

    func watchMessages(in room: String) async {
        guard let account else { return }
        while !Task.isCancelled && selection == room {
            do {
                let listed = rooms.first { $0.id == room }
                let visible = NSApp.isActive && NSApp.keyWindow != nil
                let boundary: Room?
                if visible, listed.map({ unreadCount(for: $0) > 0 }) != false {
                    boundary = try? await backend.thread(account.id, room)
                } else { boundary = nil }
                try Task.checkCancellation()
                let latest = try await backend.messages(account.id, room)
                try Task.checkCancellation()
                guard selection == room else { return }
                loadingMessages = false
                rememberMessages(latest, in: room)
                if messages != latest {
                    messages = latest
                    queueMessages()
                } else if Date() >= nextTranslationRetry {
                    queueMessages()
                }
                if !latest.isEmpty, let boundary, boundary.id == room, unreadCount(for: boundary) > 0,
                   let version = boundary.readStateVersion, !version.isEmpty,
                   NSApp.isActive, NSApp.keyWindow != nil {
                    do {
                        try await backend.markRead(account.id, room: room, version: version)
                        acknowledgedVersions[room] = version
                    } catch ConnectionError.response(409, _) {
                        // A newer message arrived. Read the new page before acknowledging it.
                    }
                }
            } catch is CancellationError { return }
            catch ConnectionError.response(404, _) where !rooms.contains(where: { $0.id == room }) {
                if selection == room, !Task.isCancelled { loadingMessages = false }
            } catch {
                if selection == room, !Task.isCancelled {
                    loadingMessages = false
                    status = UIMessage(error: error)
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refreshDirectory() async {
        guard let account, connected, !readingDirectory else { return }
        readingDirectory = true
        lastDirectoryRead = Date()
        defer { readingDirectory = false }
        do {
            async let contactsRequest = backend.contacts(account.id)
            async let groupsRequest = backend.groups(account.id)
            let (people, groupRecords) = try await (contactsRequest, groupsRequest)
            let groupIDs = Set(groupRecords.map(\.id))
            let direct = people.filter { !groupIDs.contains($0.id) && !$0.id.hasSuffix("@chatroom") }
            let extraGroups = people.filter { !groupIDs.contains($0.id) && $0.id.hasSuffix("@chatroom") }
            let displayLanguage = interfaceLanguage
            let order: (Room, Room) -> Bool = { first, second in
                if (first.name == nil) != (second.name == nil) { return first.name != nil }
                return first.title(in: displayLanguage).localizedStandardCompare(second.title(in: displayLanguage)) == .orderedAscending
            }
            let peopleRooms = direct.map(\.room).sorted(by: order)
            let groupRooms = (groupRecords.map(\.room) + extraGroups.map(\.room)).sorted(by: order)
            if contacts != peopleRooms { contacts = peopleRooms }
            if groups != groupRooms { groups = groupRooms }
            var existingNames: [String: String] = [:]
            for person in people {
                existingNames[person.id] = [person.remark, person.nickname].compactMap { $0 }.first(where: Self.isLatinName)
            }
            if registeredEnglish != existingNames { registeredEnglish = existingNames; objectWillChange.send() }
            if !syncingDirectory { directoryStatus = nil }
        } catch is CancellationError { }
        catch { directoryStatus = UIMessage("그룹·연락처 목록 읽기 실패") }
    }

    func syncDirectoryNames() async {
        guard let account, connected, !syncingDirectory else { return }
        syncingDirectory = true
        directoryStatus = UIMessage("위챗에서 그룹과 연락처 이름을 확인 중…")
        defer { syncingDirectory = false }
        var failed = false
        for sync in [backend.syncGroups, backend.syncContacts] {
            do {
                let operation = try await sync(account.id)
                try await finishMetadata(operation, account: account.id)
            } catch { failed = true }
        }
        await refreshDirectory()
        directoryStatus = failed ? UIMessage("일부 그룹 또는 연락처 이름을 새로 읽지 못했습니다.") : nil
    }

    private func finishMetadata(_ operation: Operation, account: String) async throws {
        var current = operation
        for _ in 0..<125 {
            if current.state == "succeeded" { return }
            if ["failed", "cancelled", "rejected", "needs_login"].contains(current.state) { break }
            try await Task.sleep(for: .seconds(1))
            current = try await backend.operation(account, operation.id)
        }
        throw ConnectionError.unavailable
    }

    func loadGroupRoster(_ room: String, refresh: Bool = false) async {
        guard let account, room.hasSuffix("@chatroom"), !loadingRosters.contains(room) else { return }
        if !refresh, let checked = rosterCheckedAt[room], Date().timeIntervalSince(checked) < 90 { return }
        loadingRosters.insert(room)
        defer { loadingRosters.remove(room) }
        do {
            let saved = try await backend.groupRoster(account.id, room)
            groupRosters[room] = saved
            rosterCheckedAt[room] = Date()
            if refresh || saved.isEmpty {
                let operation = try await backend.refreshGroupMembers(account.id, room)
                try await finishMetadata(operation, account: account.id)
                groupRosters[room] = try await backend.groupRoster(account.id, room)
            }
        } catch is CancellationError { }
        catch { groupInfoStatus[room] = UIMessage(error: error, prefix: "그룹 멤버 조회 실패 · %@") }
    }

    func inviteGroupMembers(_ selected: Set<String>, to room: String) async {
        guard let account, room == selection, room.hasSuffix("@chatroom"), !invitingToGroup.contains(room) else { return }
        let memberIds = Set(groupRosters[room, default: []].map(\.id))
        let contactIds = Set(contacts.map(\.id)).subtracting(memberIds)
        let requested = pendingGroupInvites[room] ?? selected.intersection(contactIds).sorted()
        guard (1...40).contains(requested.count) else { return }
        let key = groupInviteKeys[room] ?? UUID().uuidString
        groupInviteKeys[room] = key
        pendingGroupInvites[room] = requested
        invitingToGroup.insert(room)
        groupInfoStatus[room] = UIMessage("위챗에 그룹 초대를 요청하는 중…")
        defer { invitingToGroup.remove(room) }
        do {
            var result = try await backend.addGroupMembers(account.id, group: room, members: requested, key: key)
            for _ in 0..<25 where result.state == "queued" || result.state == "running" {
                try await Task.sleep(for: .seconds(1))
                result = try await backend.operation(account.id, result.id)
            }
            guard result.result?.targetId == room, result.result?.action == "add_members" else { throw ConnectionError.invalidResponse }
            switch result.state {
            case "succeeded":
                pendingGroupInvites[room] = nil
                groupInviteKeys[room] = nil
                groupInfoStatus[room] = UIMessage(result.result?.memberOutcome == "partial" ? "일부 초대 결과를 확인하지 못했습니다." : "위챗이 초대 요청을 수락했습니다.")
                await loadGroupRoster(room, refresh: true)
            case "failed", "cancelled", "rejected", "needs_login":
                pendingGroupInvites[room] = nil
                groupInviteKeys[room] = nil
                groupInfoStatus[room] = UIMessage("그룹 초대 실패 · %@", result.result?.errorCode ?? result.result?.reason ?? result.state)
            default:
                groupInfoStatus[room] = UIMessage("초대 결과를 아직 확인하지 못했습니다.")
            }
        } catch ConnectionError.response(let code, let reason) where (400..<500).contains(code) && code != 409 {
            pendingGroupInvites[room] = nil
            groupInviteKeys[room] = nil
            groupInfoStatus[room] = UIMessage(error: ConnectionError.response(code, reason), prefix: "그룹 초대 실패 · %@")
        } catch {
            groupInfoStatus[room] = UIMessage(error: error, prefix: "그룹 초대 결과 미확인 · %@")
        }
    }

    func showGroupMemberAvatar(_ member: GroupMember, in room: String) {
        showGroupSenderAvatar(member.id, in: room)
    }

    func showGroupSenderAvatar(_ id: String, in room: String) {
        guard selection == room else { return }
        enqueueAvatar(.person(id, group: room))
        startAvatarRequests()
    }

    func groupSenderName(_ id: String?, in room: String) -> String {
        guard let id else { return interfaceLanguage.label("이름 미확인 멤버") }
        let member = groupRosters[room]?.first { $0.id == id }
        return [displayNames[id], wechatContactNames[id], member?.displayName, member?.roomDisplayName,
                member?.mentionName, contacts.first(where: { $0.id == id })?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != id } ?? interfaceLanguage.label("이름 미확인 멤버")
    }

    private func avatarRoomIsVisible(_ room: String) -> Bool { selection == room || visibleAvatarRooms.contains(room) }

    func showAvatar(for room: Room) {
        guard room.id != "filehelper", room.id != "brandsessionholder" else { return }
        visibleAvatarRooms.insert(room.id)
        if room.isGroup {
            let initial = room.avatarMembers?.map(\.id) ?? []
            if groupAvatarMembers[room.id] == nil, !initial.isEmpty { groupAvatarMembers[room.id] = initial }
            for member in groupAvatarMembers[room.id] ?? [] { enqueueAvatar(.person(member, group: room.id)) }
            enqueueAvatar(.group(room.id))
        } else {
            enqueueAvatar(.person(room.id, group: nil))
        }
        startAvatarRequests()
    }

    func hideAvatar(for room: Room) {
        visibleAvatarRooms.remove(room.id)
        pendingAvatars.removeAll { $0.roomID == room.id }
    }

    private func enqueueAvatar(_ request: AvatarRequest) {
        if case .person(let id, _) = request, avatarImages[id] != nil { return }
        if let last = avatarAttempts[request], Date().timeIntervalSince(last) < 300 { return }
        guard !activeAvatars.contains(request), !pendingAvatars.contains(request) else { return }
        pendingAvatars.append(request)
    }

    private func startAvatarRequests() {
        guard let account, connected else { return }
        while activeAvatars.count < 3, !pendingAvatars.isEmpty {
            let request = pendingAvatars.removeFirst()
            guard avatarRoomIsVisible(request.roomID) else { continue }
            activeAvatars.insert(request)
            Task {
                await loadAvatar(request, account: account.id)
                activeAvatars.remove(request)
                startAvatarRequests()
            }
        }
    }

    private func loadAvatar(_ request: AvatarRequest, account: String) async {
        guard avatarRoomIsVisible(request.roomID) else { return }
        avatarAttempts[request] = Date()
        do {
            switch request {
            case .group(let id):
                var members = try await backend.groupMembers(account, id)
                if members.isEmpty, visibleAvatarRooms.contains(id) {
                    let operation = try await backend.refreshGroupMembers(account, id)
                    try await finishMetadata(operation, account: account)
                    members = try await backend.groupMembers(account, id)
                }
                var seen: Set<String> = []
                let ids = members.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
                if !ids.isEmpty {
                    groupAvatarMembers[id] = ids
                    if visibleAvatarRooms.contains(id) {
                        for member in ids { enqueueAvatar(.person(member, group: id)) }
                    }
                }
            case .person(let id, let group):
                guard avatarImages[id] == nil else { return }
                let bytes: Data
                do { bytes = try await backend.avatar(account, id) }
                catch ConnectionError.response(404, _) {
                    guard avatarRoomIsVisible(request.roomID) else { return }
                    let operation = try await backend.refreshAvatar(account, id, group: group)
                    try await finishMetadata(operation, account: account)
                    bytes = try await backend.avatar(account, id)
                }
                if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 144
                   ] as CFDictionary) {
                    avatarImages[id] = NSImage(cgImage: image, size: .zero)
                }
            }
        } catch { }
    }

    private func fetchGroupName(_ id: String, account: String) async {
        do {
            let operation = try await backend.refreshGroup(account, id)
            try await finishMetadata(operation, account: account)
            await refreshDirectory()
        } catch { }
    }

    func refreshMessageTranslations() {
        translations.removeAll()
        queueMessages()
    }

    private func queueMessages() {
        var ready: [AutomaticTranslation] = []
        nextTranslationRetry = .distantFuture
        let now = Date()
        for message in visibleMessages.reversed() where message.hasTranslatableText && !isRecalled(message) {
            guard let text = message.body else { continue }
            let mixed = MixedLanguageText(text)
            let source = mixed == nil ? Self.automaticSource(text) : nil
            guard source != nil || mixed != nil else { continue }
            let job = AutomaticTranslation(messageID: message.id, text: text, source: source, target: received.rawValue, mixed: mixed)
            guard job.source != job.target, job != inFlightTranslation else { continue }
            if let cached = translationCache[job] {
                if !cached.isEmpty, translations[job.messageID] != cached { translations[job.messageID] = cached }
            } else if let retry = translationRetries[job], retry > now {
                nextTranslationRetry = min(nextTranslationRetry, retry)
            } else {
                ready.append(job)
            }
        }
        queuedTranslations = ready
        if translationProvider == .deepL, deepLAutoRetryAfter > now {
            nextTranslationRetry = min(nextTranslationRetry, deepLAutoRetryAfter)
        }
        startAutomaticTranslation()
    }

    func runAutomaticTranslation(_ session: TranslationSession, generation: Int) async {
        guard translationProvider == .apple, generation == translationGeneration, activeAutomaticRoute?.source != nil else { return }
        await runAutomaticTranslations(generation: generation) { job in
            try await session.translate(job.text).targetText
        }
    }

    private func runAutomaticTranslations(generation: Int, translate: (AutomaticTranslation) async throws -> String) async {
        guard generation == translationGeneration, let route = activeAutomaticRoute else { return }
        defer {
            if generation == translationGeneration {
                inFlightTranslation = nil
                activeAutomaticRoute = nil
                automaticTask = nil
                startAutomaticTranslation()
            }
        }
        while !Task.isCancelled, generation == translationGeneration,
              let index = queuedTranslations.firstIndex(where: { $0.source == route.source && $0.target == route.target }) {
            let job = queuedTranslations.remove(at: index)
            inFlightTranslation = job
            do {
                let result = try await translate(job).trimmingCharacters(in: .whitespacesAndNewlines)
                guard generation == translationGeneration, !Task.isCancelled else { return }
                if result.isEmpty { throw ConnectionError.invalidResponse }
                if translationCache.count >= 4_000 {
                    let retained = Set(messageCache.values.flatMap { $0.map(\.id) })
                    translationCache = translationCache.filter { retained.contains($0.key.messageID) && $0.key.target == received.rawValue }
                }
                let translated = result == job.text.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : result
                translationCache[job] = translated
                translationRetries[job] = nil
                if job.target == received.rawValue,
                   !translated.isEmpty, messages.contains(where: { $0.id == job.messageID && $0.body == job.text }) {
                    translations[job.messageID] = translated
                }
            } catch {
                guard generation == translationGeneration else { return }
                let retry = Date().addingTimeInterval(Task.isCancelled ? 2 : 30)
                translationRetries[job] = retry
                nextTranslationRetry = min(nextTranslationRetry, retry)
                if !Task.isCancelled { status = UIMessage(error: error, prefix: "자동 번역 실패 · %@") }
                if let failure = error as? DeepLError, failure.pausesAutomaticTranslation {
                    deepLAutoRetryAfter = retry
                    return
                }
            }
            inFlightTranslation = nil
        }
    }

    private func startAutomaticTranslation() {
        guard activeAutomaticRoute == nil, let job = queuedTranslations.first, let target = Language(rawValue: job.target) else { return }
        if translationProvider == .deepL {
            guard let key = deepLKey else {
                status = DeepLError.missingKey.displayMessage
                return
            }
            guard Date() >= deepLAutoRetryAfter else { return }
            activeAutomaticRoute = (job.source, job.target)
            let generation = translationGeneration
            automaticTask = Task {
                await runAutomaticTranslations(generation: generation) { job in
                    if let mixed = job.mixed {
                        return try await mixed.translated(to: target) { text, source in
                            try await self.deepL.translate(text, source: source.rawValue, target: target, key: key)
                        }
                    }
                    return try await self.deepL.translate(job.text, source: job.source, target: target, key: key)
                }
            }
            return
        }
        activeAutomaticRoute = (job.source, job.target)
        guard let code = job.source else {
            let generation = translationGeneration
            automaticTask = Task {
                await runAutomaticTranslations(generation: generation) { job in
                    guard let mixed = job.mixed else { throw ConnectionError.invalidResponse }
                    return try await mixed.translated(to: target) { text, source in
                        try await self.mixedAutomaticApple.translate(text, from: source, to: target)
                    }
                }
            }
            return
        }
        let source = Locale.Language(identifier: code)
        let destination = Locale.Language(identifier: target.rawValue)
        if automaticConfig?.source == source, automaticConfig?.target == destination { automaticConfig?.invalidate() }
        else { automaticConfig = .init(source: source, target: destination) }
    }

    private static func isLatinName(_ title: String) -> Bool {
        title.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
            && nameSource(title) == nil
    }

    private static func nameSource(_ title: String) -> String? {
        let scalars = title.unicodeScalars
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) { return "ko" }
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if scalars.contains(where: { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }) { return "zh-Hans" }
        return nil
    }

    private static func automaticSource(_ text: String) -> String? {
        if let source = nameSource(text) { return source == "ja" ? nil : source }
        guard isLatinName(text) else { return nil }
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)
        return detected == nil || detected == .english || text.split(whereSeparator: \.isWhitespace).count <= 3 ? "en" : nil
    }

    func select(_ room: String) {
        guard room != selection, !sending else { return }
        if let selection { drafts[selection] = composerDraft }
        lastRoomSwitch = Date()
        warmingHistory?.cancel()
        selection = room
        composerDraft = drafts[room] ?? MessageDraft()
        messages = messageCache[room] ?? []
        loadingMessages = messageCache[room] == nil
        refreshMessageTranslations()
        previewDraft = nil
        if let account, room.hasSuffix("@chatroom"), listing(.all).first(where: { $0.id == room })?.name == nil,
           requestedGroupNames.insert(room).inserted {
            Task { await fetchGroupName(room, account: account.id) }
        }
    }

    func updateDraft(_ text: String, edit: DraftEdit?, in room: String) {
        guard selection == room else { return }
        var updated = composerDraft
        updated.update(text, edit: edit)
        if updated != composerDraft { composerDraft = updated }
    }

    func insertMention(_ member: GroupMember, at range: NSRange, in room: String) -> NSRange? {
        guard selection == room, room.hasSuffix("@chatroom"),
              groupRosters[room]?.contains(where: { $0.id == member.id }) == true else { return nil }
        var updated = composerDraft
        guard let caret = updated.insert(member, at: range) else { return nil }
        composerDraft = updated
        return caret
    }

    func translate(_ text: String, message: String? = nil) {
        guard !translating, let selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = message == nil ? outgoing : received
        let content = message == nil && draft == text ? composerDraft : MessageDraft(text)
        let id = UUID()
        work = (id, content, message, selection, target)
        let prose = content.prose
        let mixed = MixedLanguageText(prose) != nil
        let code = NLLanguageRecognizer.dominantLanguage(for: prose)?.rawValue
        if prose.isEmpty || (!mixed && code?.split(separator: "-").first == target.rawValue.split(separator: "-").first) {
            accept(content)
            return
        }
        translating = true
        if translationProvider == .deepL || mixed {
            let key = translationProvider == .deepL ? deepLKey : nil
            if translationProvider == .deepL && key == nil { failTranslation(DeepLError.missingKey, id: id); return }
            manualTask = Task {
                defer { if work?.id == id || work == nil { manualTask = nil } }
                do {
                    let translated = try await content.translated { segment in
                        if mixed, let plan = MixedLanguageText(segment) {
                            return try await plan.translated(to: target) { text, source in
                                if let key { return try await self.deepL.translate(text, source: source.rawValue, target: target, key: key) }
                                return try await self.mixedManualApple.translate(text, from: source, to: target)
                            }
                        }
                        if mixed, let sourceCode = Self.automaticSource(segment), let source = Language(rawValue: sourceCode) {
                            if source == target { return segment }
                            if let key { return try await deepL.translate(segment, source: sourceCode, target: target, key: key) }
                            return try await mixedManualApple.translate(segment, from: source, to: target)
                        }
                        if let key { return try await deepL.translate(segment, source: code, target: target, key: key) }
                        return segment
                    }
                    guard work?.id == id, !Task.isCancelled else { return }
                    accept(translated)
                } catch { failTranslation(error, id: id) }
            }
            return
        }
        let source = code.map { Locale.Language(identifier: $0) }
        let destination = Locale.Language(identifier: target.rawValue)
        if config?.source == source, config?.target == destination { config?.invalidate() }
        else { config = .init(source: source, target: destination) }
    }

    func runTranslation(_ session: TranslationSession, generation: Int) async {
        guard translationProvider == .apple, generation == translationGeneration, manualTask == nil, let work else { return }
        do {
            let translated = try await work.draft.translated { segment in
                try await session.translate(segment).targetText
            }
            if self.work?.id == work.id { accept(translated) }
        } catch { failTranslation(error, id: work.id) }
    }

    private func failTranslation(_ error: Error, id: UUID) {
        guard work?.id == id else { return }
        translating = false
        work = nil
        status = UIMessage(error: error, prefix: "번역 실패 · %@")
    }

    private func accept(_ translated: MessageDraft) {
        defer { translating = false; work = nil }
        guard let work else { return }
        if let message = work.message, work.language == received, selection == work.room,
           messages.contains(where: { $0.id == message && $0.body == work.draft.text }) { translations[message] = translated.text }
        else if work.message == nil, selection == work.room, composerDraft == work.draft, work.language == outgoing {
            previewDraft = translated
            previewSource = (work.draft, work.room, work.language)
            status = UIMessage("번역 완료 · Enter를 누르면 번역문을 전송합니다.")
        }
    }

    private var confirmedPreview: MessageDraft? {
        guard let previewSource, composerDraft == previewSource.draft, selection == previewSource.room,
              outgoing == previewSource.language else { return nil }
        return previewDraft
    }

    func submitComposer() async {
        guard !sending, !translating, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if confirmedPreview != nil { await send() }
        else { translate(draft) }
    }

    func send() async {
        guard let account, let selection, !sending, !translating else { return }
        let source = composerDraft
        let quote = quotedMessage
        if let quote, isRecalled(quote) {
            status = UIMessage("회수된 메시지입니다. 인용을 취소한 뒤 전송하세요.")
            return
        }
        guard let request = (confirmedPreview ?? source).request(for: selection, quote: quote?.quoteReference) else { return }
        sending = true
        defer { sending = false }
        let key = sendKeys[selection].flatMap { $0.request == request ? $0.key : nil } ?? UUID().uuidString
        sendKeys[selection] = (request, key)
        do {
            var sent = try await backend.send(account.id, request: request, key: key)
            for _ in 0..<10 where sent.state == "queued" || sent.state == "submitting" {
                try await Task.sleep(for: .milliseconds(650))
                sent = try await backend.checkSend(account.id, sent.id)
            }
            guard sent.destination == selection else { throw ConnectionError.invalidResponse }
            switch sent.state {
            case "accepted":
                if composerDraft == source { composerDraft = MessageDraft() }
                if quotedMessages[selection] == quote { quotedMessages[selection] = nil }
                sendKeys[selection] = nil
                status = UIMessage("위챗에서 전송을 수락했습니다.")
            case "failed", "cancelled":
                sendKeys[selection] = nil
                status = UIMessage("전송 실패 · %@", sent.errorCode ?? sent.state)
            default: status = UIMessage("전송 확인 대기 중 · 같은 문장을 다시 누르면 기존 요청의 결과를 확인합니다.")
            }
        } catch { status = UIMessage(error: error, prefix: "전송 결과 미확인 · %@") }
    }

    func setQuote(_ message: Message?, in room: String) {
        guard !sending, selection == room else { return }
        if let message, isRecalled(message) || message.quoteReference == nil { return }
        quotedMessages[room] = message
    }

    func isRecalled(_ message: Message) -> Bool {
        message.isRecalled || confirmedRecalls.contains(message.id)
    }

    func searchMessages(in room: String, query: String, cursor: String?) async throws -> Page<Message> {
        guard let account, selection == room else { throw CancellationError() }
        let page = try await backend.searchMessages(account.id, room: room, query: query, cursor: cursor)
        try Task.checkCancellation()
        guard selection == room else { throw CancellationError() }
        let hidden = Set(hiddenMessageIDs[account.id] ?? [])
        return Page(items: page.items.filter { !hidden.contains($0.id) && !isRecalled($0) }, nextCursor: page.nextCursor)
    }

    func canRecall(_ message: Message) -> Bool {
        message.outgoing && message.type > 0 && message.type < 10000
            && message.threadId == selection && message.confirmedServerID != nil && !isRecalled(message)
    }

    func recall(_ message: Message, in room: String) async {
        guard let account, room == selection, message.threadId == room, canRecall(message),
              let serverID = message.confirmedServerID, pendingRecalls.insert(message.id).inserted else { return }
        let key = recallKeys[message.id] ?? UUID().uuidString
        recallKeys[message.id] = key
        status = UIMessage("위챗에 메시지 회수를 요청하는 중…")
        defer { pendingRecalls.remove(message.id) }
        do {
            var operation = try await backend.recall(account.id, message: message.id, serverID: serverID, key: key)
            for _ in 0..<20 where ["queued", "running"].contains(operation.state) {
                try await Task.sleep(for: .milliseconds(750))
                operation = try await backend.operation(account.id, operation.id)
            }
            guard operation.result?.messageId == message.id, operation.result?.threadId == room,
                  operation.result?.serverId == serverID else { throw ConnectionError.invalidResponse }
            switch operation.state {
            case "succeeded":
                confirmedRecalls.insert(message.id)
                translations[message.id] = nil
                if selection == room { queueMessages() }
                status = UIMessage("메시지를 회수했습니다.")
            case "failed", "cancelled":
                status = operation.result?.status == "not_eligible"
                    ? UIMessage("위챗에서 이 메시지의 회수를 허용하지 않았습니다.")
                    : UIMessage("메시지 회수 실패 · %@", operation.result?.status ?? operation.state)
            default:
                status = UIMessage("회수 결과를 아직 확인하지 못했습니다. 다시 선택하면 같은 요청을 확인합니다.")
            }
        } catch { status = UIMessage(error: error, prefix: "회수 결과 미확인 · %@") }
    }

    func hideMessage(_ message: Message) {
        guard let account, !hiddenMessageIDs[account.id, default: []].contains(message.id) else { return }
        hiddenMessageIDs[account.id, default: []].append(message.id)
        preferences.set(hiddenMessageIDs, forKey: "hiddenMessageIDs")
        lastHiddenMessage = message.id
        status = UIMessage("이 앱에서 메시지를 숨겼습니다.")
        queueMessages()
    }

    func undoHideMessage() {
        guard let account, let lastHiddenMessage else { return }
        hiddenMessageIDs[account.id]?.removeAll { $0 == lastHiddenMessage }
        preferences.set(hiddenMessageIDs, forKey: "hiddenMessageIDs")
        self.lastHiddenMessage = nil
        status = UIMessage("숨긴 메시지를 복원했습니다.")
        queueMessages()
    }

    func chooseFile() {
        guard let selection, !sendingFiles.contains(selection) else { return }
        let panel = NSOpenPanel()
        panel.title = interfaceLanguage.label("보낼 파일 선택")
        panel.prompt = interfaceLanguage.label("첨부")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let file = panel.url else { return }
            self.attachments[selection] = PendingAttachment(file: file)
        }
    }

    func removeFile(_ room: String) {
        guard !sendingFiles.contains(room) else { return }
        attachments[room] = nil
    }

    func sendFile() async {
        guard let account, let room = selection, var file = attachments[room], sendingFiles.insert(room).inserted else { return }
        status = UIMessage("파일 전송 준비 중…")
        defer { sendingFiles.remove(room) }
        do {
            let source: String
            if let previous = file.source { source = previous }
            else {
                source = try await backend.upload(account.id, file: file.file)
                file.source = source
                attachments[room] = file
            }
            let started: MediaJob
            if let job = file.job { started = try await backend.mediaJob(account.id, job) }
            else { started = try await backend.sendFile(account.id, room: room, source: source, key: file.key) }
            guard started.threadId == room, started.kind == "send", started.sourceId == source else {
                throw ConnectionError.invalidResponse
            }
            file.job = started.id
            attachments[room] = file
            let result = try await backend.waitForMedia(account.id, initial: started)
            switch result.state {
            case "accepted":
                attachments[room] = nil
                status = UIMessage("위챗에서 파일 전송을 수락했습니다.")
            case "failed", "cancelled", "expired", "unsupported":
                attachments[room] = PendingAttachment(file: file.file)
                status = UIMessage("파일 전송 실패 · %@", result.reason ?? result.state)
            default:
                status = UIMessage("파일 전송 결과 확인 대기 중 · ‘전송 확인’을 누르면 기존 요청을 확인합니다.")
            }
        } catch {
            status = UIMessage(error: error, prefix: file.source == nil ? "파일 준비 실패 · %@" : "파일 전송 결과 미확인 · %@")
        }
    }

    func saveAttachment(_ message: Message) async {
        guard let account, downloading.insert(message.id).inserted else { return }
        status = UIMessage("첨부파일을 가져오는 중…")
        defer { downloading.remove(message.id) }
        do {
            let asset = try await backend.attachment(account.id, message: message.id)
            let panel = NSSavePanel()
            panel.title = interfaceLanguage.label("첨부파일 저장")
            panel.prompt = interfaceLanguage.label("저장")
            panel.nameFieldStringValue = asset.saveName(in: interfaceLanguage)
            panel.canCreateDirectories = true
            guard await panel.begin() == .OK, let destination = panel.url else {
                status = UIMessage("파일 저장을 취소했습니다.")
                return
            }
            try await backend.save(asset, to: destination)
            status = UIMessage("파일을 저장했습니다: %@", destination.lastPathComponent)
        } catch { status = UIMessage(error: error, prefix: "파일 저장 실패 · %@") }
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @State private var loginTask: Task<Void, Never>?
    @State private var search = ""
    @State private var filter = RoomFilter.all
    @State private var roomToRename: Room?
    @State private var editingName = ""
    @State private var showingNameEditor = false
    @State private var showingLanguageSettings = false
    @State private var deepLKeyInput = ""
    @State private var showingChatInfo = false
    @State private var messageToRecall: Message?
    @State private var confirmingRecall = false
    @State private var showingHistorySearch = false
    @State private var editorSelection: NSRange?
    @State private var composerPlacement: ComposerPlacement?
    @State private var dismissedMention: MentionQuery?
    @State private var mentionIndex = 0

    private var language: Language { model.interfaceLanguage }

    private var mentionQuery: MentionQuery? {
        guard model.selection?.hasSuffix("@chatroom") == true, let editorSelection,
              let query = MentionQuery(text: model.draft, selection: editorSelection), query != dismissedMention else { return nil }
        return query
    }

    var body: some View {
        Group {
            if model.connected { chats }
            else { login }
        }
        .frame(minWidth: 820, minHeight: 620)
        .task { await model.start(); await model.poll() }
        .translationTask(model.config) { [generation = model.translationGeneration] session in
            await model.runTranslation(session, generation: generation)
        }
        .translationTask(model.automaticConfig) { [generation = model.translationGeneration] session in
            await model.runAutomaticTranslation(session, generation: generation)
        }
        .background(AppleTranslationRouteView(route: model.mixedAutomaticApple))
        .background(AppleTranslationRouteView(route: model.mixedManualApple))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.backend.stop() }
        .alert(language.label("이 앱의 표시 이름"), isPresented: $showingNameEditor, presenting: roomToRename) { room in
            TextField(language.label("표시 이름"), text: $editingName)
            Button(language.label("저장")) { model.setDisplayName(editingName, for: room) }
            if model.displayNames[room.id] != nil {
                Button(language.label("위챗에서 받은 이름 사용")) { model.setDisplayName("", for: room) }
            }
            Button(language.label("취소"), role: .cancel) { }
        }
        .alert(language.label("메시지를 회수하시겠습니까?"), isPresented: $confirmingRecall, presenting: messageToRecall) { message in
            Button(language.label("회수"), role: .destructive) {
                if let room = message.threadId { Task { await model.recall(message, in: room) } }
            }
            Button(language.label("취소"), role: .cancel) { }
        }
    }

    private var login: some View {
        VStack(spacing: 18) {
            Text(language.label("위챗 번역")).font(.largeTitle.bold())
            if let qr = model.qr {
                Image(nsImage: qr).resizable().interpolation(.none).scaledToFit().frame(width: 245, height: 245)
                    .accessibilityLabel(language.label("위챗 로그인 QR 코드"))
            }
            Text(model.status.text(in: language)).foregroundStyle(.secondary).textSelection(.enabled)
            if model.loggingIn { Button(language.label("취소")) { loginTask?.cancel() } }
            else if model.ready { Button(language.label("QR 로그인")) { loginTask = Task { await model.login() } }.buttonStyle(.borderedProminent) }
            else { Button(language.label("다시 연결")) { Task { await model.start() } } }
            languageSettings
        }.padding(25)
    }

    private var chats: some View {
        let listed = model.listing(filter)
        let matches = listed.filter {
            search.isEmpty || $0.title(in: language).localizedCaseInsensitiveContains(search)
                || model.englishSearchAlias($0)?.localizedCaseInsensitiveContains(search) == true
                || ($0.isGroup && $0.id.localizedCaseInsensitiveContains(search))
        }
        let selected = model.listing(.all).first { $0.id == model.selection }
        return HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text(language.label("대화")).font(.title2.bold())
                Picker(language.label("목록"), selection: $filter) {
                    ForEach(RoomFilter.allCases) { Text(language.label($0.rawValue)).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
                TextField(language.label("대화 검색"), text: $search)
                HStack {
                    Text(language.label("%@개", matches.count.formatted())).foregroundStyle(.secondary)
                    Spacer()
                    Button(language.label("목록 새로고침"), systemImage: "arrow.clockwise") { Task { await model.syncDirectoryNames() } }
                        .labelStyle(.iconOnly).help(language.label("그룹과 연락처 다시 읽기"))
                }.font(.caption)
                if let status = model.directoryStatus { Text(status.text(in: language)).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if search.isEmpty, filter == .all || filter == .chats, !listed.contains(where: { $0.id == "filehelper" }) {
                            roomButton(Room(id: "filehelper", displayName: nil, unreadCount: nil))
                        }
                        ForEach(matches) { room in
                            roomButton(room)
                        }
                    }
                }
            }.padding(14).frame(minWidth: 215, idealWidth: 250, maxWidth: 300)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selected?.title(in: language) ?? language.label(model.selection == "filehelper" ? "파일 전송" : "대화를 선택하세요"))
                        .font(.title2.bold())
                    Spacer()
                    picker("번역 언어", $model.received)
                    languageSettings
                    if let room = model.selection {
                        Button(language.label("대화 기록 검색"), systemImage: "magnifyingglass") { showingHistorySearch.toggle() }
                            .labelStyle(.iconOnly)
                            .help(language.label("대화 기록 검색"))
                            .popover(isPresented: $showingHistorySearch, arrowEdge: .bottom) {
                                ChatHistorySearch(model: model, room: room).id(room)
                            }
                    }
                    if let room = selected, !["filehelper", "brandsessionholder"].contains(room.id) { chatInfo(room) }
                }
                Divider()
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if model.loadingMessages { ProgressView(language.label("대화 불러오는 중…")).padding(.top, 28) }
                            else if model.visibleMessages.isEmpty, model.selection != nil { Text(language.label("표시할 메시지가 없습니다.")).foregroundStyle(.secondary).padding(.top, 28) }
                            if let room = model.selection {
                                ForEach(model.visibleMessages) { message in bubble(message, in: room) }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                    }.onChange(of: model.messages.last?.id) { _, _ in scroller.scrollTo("latest", anchor: .bottom) }
                }
                if let room = model.selection {
                    Divider()
                    if let message = model.quotedMessage {
                        HStack {
                            Label(quotePreview(message, in: room), systemImage: "quote.bubble")
                                .lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            Button(language.label("인용 취소"), systemImage: "xmark") { model.setQuote(nil, in: room) }
                                .labelStyle(.iconOnly).disabled(model.sending)
                        }.font(.caption)
                    }
                    if let query = mentionQuery { mentionPicker(room: room, query: query) }
                    MessageComposer(text: model.draft, label: language.label("위챗 초안"), placement: composerPlacement,
                                    onEdit: { text, edit, caret in
                        guard model.selection == room else { return }
                        dismissedMention = nil
                        model.updateDraft(text, edit: edit, in: room)
                        editorSelection = caret
                    }, onSelection: { caret in
                        if model.selection == room { editorSelection = caret }
                    }, navigate: { navigateMentions($0, room: room) }) {
                        if let query = mentionQuery {
                            let choices = mentionChoices(room, query: query)
                            if !choices.isEmpty { chooseMention(choices[min(mentionIndex, choices.count - 1)], query: query, room: room) }
                        } else {
                            Task { await model.submitComposer() }
                        }
                    }.id(room).frame(height: 84)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    if let preview = model.preview {
                        MessageComposer(text: preview, editable: false, label: language.label("번역문")) {
                            Task { await model.submitComposer() }
                        }.frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    }
                    if let file = model.attachments[room] {
                        HStack {
                            Label(file.file.lastPathComponent, systemImage: "doc").lineLimit(1)
                            Spacer()
                            Button(language.label("첨부 제거"), systemImage: "xmark") { model.removeFile(room) }.labelStyle(.iconOnly)
                                .disabled(model.sendingFiles.contains(room))
                            Button(language.label(model.sendingFiles.contains(room) ? "파일 전송 중…" : file.source == nil ? "파일 보내기" : "전송 확인")) {
                                Task { await model.sendFile() }
                            }.disabled(model.sendingFiles.contains(room))
                        }
                    }
                    HStack {
                        if room.hasSuffix("@chatroom") {
                            Button(language.label("멤버 멘션"), systemImage: "at") { beginMention(in: room) }
                                .labelStyle(.iconOnly).help(language.label("멤버 멘션"))
                        }
                        Button(language.label("파일 첨부"), systemImage: "paperclip") { model.chooseFile() }.labelStyle(.iconOnly).help(language.label("파일 첨부"))
                            .disabled(model.attachments[room] != nil)
                        picker("보낼 글", $model.outgoing)
                        Button(language.label("초안 번역")) { model.translate(model.draft) }.disabled(model.draft.isEmpty || model.translating)
                        Spacer()
                        Text(language.label(model.preview == nil ? "Enter: 번역 · Shift+Enter: 줄바꿈" : "Enter: 번역문 전송"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(language.label("전송")) { Task { await model.send() } }.buttonStyle(.borderedProminent)
                            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sending || model.translating)
                    }
                }
                HStack {
                    Text(model.status.text(in: language)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if model.lastHiddenMessage != nil {
                        Button(language.label("최근 숨김 취소")) { model.undoHideMessage() }.buttonStyle(.link)
                    }
                }
            }.padding(18).frame(minWidth: 515)
                .task(id: model.selection) {
                    if let room = model.selection { await model.watchMessages(in: room) }
                }
                .task(id: model.selection) {
                    if let room = model.selection, room.hasSuffix("@chatroom") { await model.loadGroupRoster(room) }
                }
                .onChange(of: mentionQuery) { _, _ in mentionIndex = 0 }
                .onChange(of: model.selection) { _, _ in
                    editorSelection = nil
                    composerPlacement = nil
                    dismissedMention = nil
                    showingChatInfo = false
                    showingHistorySearch = false
                }
        }
    }

    private func mentionChoices(_ room: String, query: MentionQuery) -> [GroupMember] {
        Array((model.groupRosters[room] ?? []).lazy.filter { $0.matches(query.prefix) }.prefix(30))
    }

    private func mentionPicker(room: String, query: MentionQuery) -> some View {
        let choices = mentionChoices(room, query: query)
        return VStack(alignment: .leading, spacing: 4) {
            if choices.isEmpty {
                Text(language.label(model.loadingRosters.contains(room) ? "그룹 멤버를 불러오는 중…" : "일치하는 그룹 멤버가 없습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, member in
                                Button { chooseMention(member, query: query, room: room) } label: {
                                    Text(member.name).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(index == mentionIndex ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                }.buttonStyle(.plain).id(index)
                            }
                        }
                    }.frame(height: min(130, CGFloat(choices.count) * 24))
                    .onChange(of: mentionIndex) { _, index in reader.scrollTo(index) }
                }
            }
        }.padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(language.label("멘션할 그룹 멤버"))
    }

    private func navigateMentions(_ key: UInt16, room: String) -> Bool {
        guard let query = mentionQuery else { return false }
        if key == 53 { dismissedMention = query; return true }
        let count = mentionChoices(room, query: query).count
        guard count > 0 else { return false }
        mentionIndex = (mentionIndex + (key == 125 ? 1 : count - 1)) % count
        return true
    }

    private func beginMention(in room: String) {
        let caret = editorSelection ?? NSRange(location: model.draft.utf16.count, length: 0)
        guard let range = Range(caret, in: model.draft) else { return }
        let before = model.draft[..<range.lowerBound].last
        let value = before == nil || before?.isWhitespace == true ? "@" : " @"
        let text = model.draft.replacingCharacters(in: range, with: value)
        model.updateDraft(text, edit: DraftEdit(range: caret, replacement: value), in: room)
        let next = NSRange(location: caret.location + value.utf16.count, length: 0)
        editorSelection = next
        dismissedMention = nil
        composerPlacement = ComposerPlacement(range: next)
    }

    private func chooseMention(_ member: GroupMember, query: MentionQuery, room: String) {
        guard query == mentionQuery, let caret = model.insertMention(member, at: query.range, in: room) else { return }
        editorSelection = caret
        composerPlacement = ComposerPlacement(range: caret)
    }

    private func chatInfo(_ room: Room) -> some View {
        Button(language.label(room.isGroup ? "그룹 정보" : "연락처 프로필"), systemImage: "ellipsis") { showingChatInfo.toggle() }
            .labelStyle(.iconOnly)
            .help(language.label(room.isGroup ? "그룹 정보" : "연락처 프로필"))
            .popover(isPresented: $showingChatInfo, arrowEdge: .bottom) {
                if room.isGroup {
                    GroupChatInfo(model: model, room: room.id, title: room.title(in: language))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            RoomAvatar(room: room, members: [], images: model.avatarImages)
                            Text(room.title(in: language)).font(.headline)
                        }
                        Button(language.label("별칭 수정…")) {
                            showingChatInfo = false
                            beginNameEdit(room)
                        }
                        if let name = model.wechatContactNames[room.id], model.displayNames[room.id] != nil {
                            Text(language.label("위챗 이름: %@", name)).foregroundStyle(.secondary)
                            Button(language.label("위챗에서 받은 이름 사용")) { model.setDisplayName("", for: room) }
                        }
                        if let status = model.contactNameStatus[room.id] {
                            Text(status.text(in: language)).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(language.label("위챗 이름 새로고침"), systemImage: "arrow.clockwise") {
                            Task { await model.refreshContactName(room) }
                        }.disabled(model.checkingContactNames.contains(room.id))
                    }.padding(16).frame(minWidth: 230, alignment: .leading)
                        .task(id: room.id) { await model.refreshContactName(room) }
                }
            }
    }

    private func beginNameEdit(_ room: Room) {
        roomToRename = room
        editingName = room.name ?? ""
        showingNameEditor = true
    }

    private var languageSettings: some View {
        Button(language.label("언어 설정"), systemImage: "gearshape") { showingLanguageSettings.toggle() }
            .labelStyle(.iconOnly)
            .help(language.label("언어 설정"))
            .popover(isPresented: $showingLanguageSettings, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.label("언어 설정")).font(.headline)
                    Picker(language.label("앱 화면"), selection: $model.interfacePreference) {
                        Text(language.label("시스템 기본값")).tag(nil as Language?)
                        ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    picker("받는 메시지 번역", $model.received)
                    picker("보내는 메시지 번역", $model.outgoing)
                    Divider()
                    Picker(language.label("번역 엔진"), selection: Binding(get: { model.translationProvider }, set: model.selectTranslationProvider)) {
                        ForEach(TranslationProvider.allCases) { Text($0.title).tag($0) }
                    }
                    Text(language.label("DeepL을 선택하면 번역할 메시지와 초안이 DeepL 서버로 전송되며 API 사용량이 차감됩니다."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.translationProvider == .deepL { deepLSettings }
                    Button(language.label("완료")) { showingLanguageSettings = false }
                }.padding(16).frame(width: 360)
                    .onDisappear { deepLKeyInput = "" }
            }
    }

    private var deepLSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.label(model.hasDeepLKey ? "DeepL API 키가 저장되어 있습니다." : "본인의 DeepL API 키를 입력하세요."))
                .font(.callout)
            SecureField("DeepL API key", text: $deepLKeyInput, prompt: Text(language.label("DeepL API 키")))
                .accessibilityLabel(language.label("DeepL API 키"))
            HStack {
                Button(language.label(model.checkingDeepLKey ? "키 확인 중…" : "키 확인 및 저장")) {
                    let input = deepLKeyInput
                    Task { if await model.saveDeepLKey(input) { deepLKeyInput = "" } }
                }.disabled(deepLKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.checkingDeepLKey)
                if model.hasDeepLKey {
                    Button(language.label("키 삭제")) { model.removeDeepLKey() }.disabled(model.checkingDeepLKey)
                }
            }
            if let status = model.deepLSettingsStatus {
                Text(status.text(in: language)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func roomButton(_ room: Room) -> some View {
        let members = model.groupAvatarMembers[room.id] ?? []
        let photoCount = members.filter { model.avatarImages[$0] != nil }.count
        let title = room.title(in: language)
        return Button { model.select(room.id) } label: {
            HStack(spacing: 10) {
                RoomAvatar(room: room, members: members, images: model.avatarImages)
                Text(title).lineLimit(1)
                Spacer()
                let unread = model.unreadCount(for: room)
                if unread > 0 { Text("\(unread)").foregroundStyle(.secondary) }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(model.selection == room.id ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(room.isGroup ? (photoCount > 0 ? language.label("그룹 참가자 사진 %@개", String(photoCount)) : "") : (model.avatarImages[room.id] != nil ? language.label("프로필 사진") : ""))
        .help(room.isGroup && room.name == nil ? room.id : title)
        .onAppear { model.showAvatar(for: room) }
        .onDisappear { model.hideAvatar(for: room) }
        .contextMenu {
            if room.id != "filehelper", room.id != "brandsessionholder" {
                Button(language.label("표시 이름 지정…")) {
                    beginNameEdit(room)
                }
            }
        }
    }

    private func bubble(_ message: Message, in room: String) -> some View {
        let recalled = model.isRecalled(message)
        let showSender = room.hasSuffix("@chatroom") && !message.outgoing && message.hasSender && !recalled
        return HStack(alignment: .top, spacing: 8) {
            if message.outgoing { Spacer(minLength: 65) }
            if showSender { groupSenderAvatar(message.senderId, in: room) }
            VStack(alignment: .leading, spacing: 4) {
                if showSender {
                    Text(model.groupSenderName(message.senderId, in: room))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                messageContent(message, recalled: recalled)
            }
            .contextMenu {
                messageActions(message, in: room)
            }
            Menu {
                messageActions(message, in: room)
            } label: {
                Label(language.label("메시지 메뉴"), systemImage: "ellipsis").labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(language.label("메시지 메뉴"))
            .padding(.top, showSender ? 21 : 4)
            if !message.outgoing { Spacer(minLength: 65) }
        }
    }

    @ViewBuilder
    private func messageActions(_ message: Message, in room: String) -> some View {
        if !model.isRecalled(message), let text = message.body, !text.isEmpty {
            Button(language.label("복사"), systemImage: "document.on.document") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        if !model.isRecalled(message), message.quoteReference != nil {
            Button(language.label("인용 답장"), systemImage: "quote.bubble") { model.setQuote(message, in: room) }
        }
        if model.canRecall(message) {
            Button(language.label("회수"), systemImage: "arrow.uturn.backward") {
                messageToRecall = message
                confirmingRecall = true
            }.disabled(model.pendingRecalls.contains(message.id))
        }
        Button(language.label("이 앱에서 숨기기"), systemImage: "eye.slash") { model.hideMessage(message) }
    }

    private func groupSenderAvatar(_ id: String?, in room: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.13)
            if let id, let image = model.avatarImages[id] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .onAppear { if let id { model.showGroupSenderAvatar(id, in: room) } }
    }

    private func quotePreview(_ message: Message, in room: String) -> String {
        if model.isRecalled(message) { return language.label("회수된 메시지") }
        let body = message.body ?? message.attachmentLabelKey.map { language.label($0) } ?? language.label("인용한 메시지")
        let author = message.outgoing ? language.label("나")
            : room.hasSuffix("@chatroom") ? model.groupSenderName(message.senderId, in: room) : nil
        return author.map { "\($0) · \(body)" } ?? body
    }

    private func messageContent(_ message: Message, recalled: Bool) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                if recalled {
                    Text(language.label("회수된 메시지")).foregroundStyle(.secondary)
                } else if let attachment = message.attachmentLabelKey {
                    Label(message.body ?? language.label(attachment), systemImage: "doc").textSelection(.enabled)
                    Button(language.label(model.downloading.contains(message.id) ? "가져오는 중…" : "첨부파일 저장…"), systemImage: "arrow.down.to.line") {
                        Task { await model.saveAttachment(message) }
                    }.buttonStyle(.link).disabled(model.downloading.contains(message.id))
                } else { Text(message.body ?? language.label("[첨부 또는 시스템 메시지]")).textSelection(.enabled) }
                if !recalled, let translated = model.translations[message.id] { Divider(); Text(translated).textSelection(.enabled) }
                if !recalled, message.hasTranslatableText, let body = message.body, model.translations[message.id] == nil {
                    Button(language.label("번역")) { model.translate(body, message: message.id) }.buttonStyle(.link).disabled(model.translating)
                }
                if !recalled, let quote = message.quote {
                    let text = quote.state == "recalled" ? language.label("회수된 메시지")
                        : quote.embeddedText ?? language.label("인용한 메시지")
                    Divider()
                    Label(quote.senderName.map { "\($0) · \(text)" } ?? text, systemImage: "quote.bubble")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }.padding(10).background(message.outgoing ? Color.green.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func picker(_ label: String, _ selection: Binding<Language>) -> some View {
        Picker(language.label(label), selection: selection) { ForEach(Language.allCases) { Text($0.title).tag($0) } }.fixedSize()
    }
}

@main
struct NativeTranslatorApp: App {
    @StateObject private var model = ChatModel()
    var body: some Scene { Window("WeChat Native Translator", id: "wechat-native-translator") { ChatView(model: model) }.defaultSize(width: 1100, height: 740) }
}
