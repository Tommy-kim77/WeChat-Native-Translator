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
    @Published private var removedRoomNamesByAccount: [String: [String: String]]
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
    @Published private(set) var automaticTranslations: [String: String] = [:]
    @Published var automaticTranslationEnabled: Bool {
        didSet {
            guard automaticTranslationEnabled != oldValue else { return }
            preferences.set(automaticTranslationEnabled, forKey: "automaticTranslationEnabled")
            if automaticTranslationEnabled { queueMessages() }
            else {
                stopAutomaticTranslation()
                automaticTranslations.removeAll()
            }
        }
    }
    @Published private(set) var previewDraft: MessageDraft?
    var preview: String? { previewDraft?.text }
    var canSend: Bool {
        let text = (confirmedPreview ?? composerDraft).text
        return !sending && !translating && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldTranslateOnEnter: Bool {
        confirmedPreview == nil && automaticTranslationEnabled && !composerDraft.isWebLinkOnly
    }
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
    private(set) var automaticTranslationGeneration = 0
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
    @Published private var messageCache: [String: [Message]] = [:]
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
        self.removedRoomNamesByAccount = preferences.object(forKey: "removedRoomNamesByAccount") as? [String: [String: String]] ?? [:]
        let system = Language.preferred(from: preferredLanguages)
        self.systemLanguage = system
        self.interfacePreference = preferences.string(forKey: "interfaceLanguage").flatMap(Language.init(rawValue:))
        self.received = preferences.string(forKey: "receivedLanguage").flatMap(Language.init(rawValue:)) ?? system
        self.outgoing = preferences.string(forKey: "outgoingLanguage").flatMap(Language.init(rawValue:)) ?? .english
        self.automaticTranslationEnabled = preferences.object(forKey: "automaticTranslationEnabled") as? Bool ?? true
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
        stopAutomaticTranslation()
        manualTask?.cancel()
        manualTask = nil
        work = nil
        translating = false
        previewDraft = nil
        config = nil
        translationCache.removeAll()
        translationRetries.removeAll()
        deepLAutoRetryAfter = .distantPast
        refreshMessageTranslations()
    }

    private func stopAutomaticTranslation() {
        automaticTranslationGeneration += 1
        automaticTask?.cancel()
        automaticTask = nil
        activeAutomaticRoute = nil
        inFlightTranslation = nil
        queuedTranslations.removeAll()
        nextTranslationRetry = .distantFuture
        automaticConfig = nil
    }

    func listing(_ filter: RoomFilter) -> [Room] {
        switch filter {
        case .chats:
            let names = Dictionary((groups + contacts).compactMap { room in room.name.map { (room.id, $0) } },
                                   uniquingKeysWith: { first, _ in first })
            return rooms.filter { !isRoomRemoved($0.id) }.map { room in
                guard let name = displayNames[room.id] ?? wechatContactNames[room.id] ?? names[room.id] else { return room }
                return room.withName(name)
            }
        case .groups: return groups.filter { !isRoomRemoved($0.id) }.map(applyDisplayName)
        case .contacts: return contacts.filter { !isRoomRemoved($0.id) }.map(applyDisplayName)
        case .all:
            let chats = listing(.chats)
            var seen = Set(chats.map(\.id))
            let directory = (listing(.groups) + listing(.contacts)).filter { seen.insert($0.id).inserted }
            return chats + directory.filter { !$0.isGroup || $0.name != nil } + directory.filter { $0.isGroup && $0.name == nil }
        }
    }

    private func applyDisplayName(_ room: Room) -> Room {
        (displayNames[room.id] ?? wechatContactNames[room.id]).map(room.withName) ?? room
    }

    private var removedRoomNames: [String: String] {
        guard let account else { return [:] }
        return removedRoomNamesByAccount[account.id] ?? [:]
    }

    var removedRooms: [Room] {
        removedRoomNames.map { Room(id: $0.key, displayName: $0.value, unreadCount: nil) }
            .sorted { first, second in
                let order = first.title(in: interfaceLanguage).localizedStandardCompare(second.title(in: interfaceLanguage))
                return order == .orderedSame ? first.id < second.id : order == .orderedAscending
            }
    }

    func isRoomRemoved(_ id: String) -> Bool { removedRoomNames[id] != nil }

    func canRemoveRoom(_ id: String) -> Bool {
        account != nil && !sending && !sendingFiles.contains(id) && !isRoomRemoved(id)
    }

    func removeRoomFromList(_ room: Room) {
        guard let account, canRemoveRoom(room.id) else { return }
        removedRoomNamesByAccount[account.id, default: [:]][room.id] = room.name ?? ""
        preferences.set(removedRoomNamesByAccount, forKey: "removedRoomNamesByAccount")
        if selection == room.id { select(nil) }
        status = UIMessage("대화방을 목록에서 삭제했습니다. 대화 기록은 보관됩니다.")
    }

    func restoreRoomToList(_ id: String) {
        guard let account, isRoomRemoved(id) else { return }
        removedRoomNamesByAccount[account.id]?.removeValue(forKey: id)
        preferences.set(removedRoomNamesByAccount, forKey: "removedRoomNamesByAccount")
        status = UIMessage("대화방을 목록에 복원했습니다.")
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
        if messageCache[room] != latest { messageCache[room] = latest }
        cacheOrder.removeAll { $0 == room }
        cacheOrder.append(room)
        if cacheOrder.count > 50 { messageCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    func latestMessage(in room: String) -> Message? {
        let hidden = account.flatMap { hiddenMessageIDs[$0.id] } ?? []
        let recent = selection == room ? messages : messageCache[room] ?? []
        return recent.last { !hidden.contains($0.id) }
    }

    func latestSummary(for room: Room) -> RoomMessageSummary? {
        guard let summary = room.lastMessage else { return nil }
        let hidden = account.flatMap { hiddenMessageIDs[$0.id] } ?? []
        return hidden.contains(summary.id) ? nil : summary
    }

    private func warmRecentHistory(_ account: String) {
        guard warmingHistory == nil, Date().timeIntervalSince(lastRoomSwitch) >= 5 else { return }
        let targets = rooms.prefix(6).filter { $0.id != selection && !isRoomRemoved($0.id) && messageCache[$0.id] == nil }
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
        automaticTranslations.removeAll()
        queueMessages()
    }

    private func queueMessages() {
        guard automaticTranslationEnabled else { return }
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
                if !cached.isEmpty, automaticTranslations[job.messageID] != cached { automaticTranslations[job.messageID] = cached }
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
        guard translationProvider == .apple, generation == automaticTranslationGeneration, activeAutomaticRoute?.source != nil else { return }
        await runAutomaticTranslations(generation: generation) { job in
            try await session.translate(job.text).targetText
        }
    }

    private func runAutomaticTranslations(generation: Int, translate: (AutomaticTranslation) async throws -> String) async {
        guard generation == automaticTranslationGeneration, let route = activeAutomaticRoute else { return }
        defer {
            if generation == automaticTranslationGeneration {
                inFlightTranslation = nil
                activeAutomaticRoute = nil
                automaticTask = nil
                startAutomaticTranslation()
            }
        }
        while !Task.isCancelled, generation == automaticTranslationGeneration,
              let index = queuedTranslations.firstIndex(where: { $0.source == route.source && $0.target == route.target }) {
            let job = queuedTranslations.remove(at: index)
            inFlightTranslation = job
            do {
                let result = try await translate(job).trimmingCharacters(in: .whitespacesAndNewlines)
                guard generation == automaticTranslationGeneration, !Task.isCancelled else { return }
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
                    automaticTranslations[job.messageID] = translated
                }
            } catch {
                guard generation == automaticTranslationGeneration else { return }
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
        guard automaticTranslationEnabled, activeAutomaticRoute == nil,
              let job = queuedTranslations.first, let target = Language(rawValue: job.target) else { return }
        if translationProvider == .deepL {
            guard let key = deepLKey else {
                status = DeepLError.missingKey.displayMessage
                return
            }
            guard Date() >= deepLAutoRetryAfter else { return }
            activeAutomaticRoute = (job.source, job.target)
            let generation = automaticTranslationGeneration
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
            let generation = automaticTranslationGeneration
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

    func select(_ room: String?) {
        guard room != selection, !sending else { return }
        if let room, isRoomRemoved(room) { return }
        if let selection { drafts[selection] = composerDraft }
        lastRoomSwitch = Date()
        warmingHistory?.cancel()
        selection = room
        composerDraft = room.flatMap { drafts[$0] } ?? MessageDraft()
        let cachedMessages = room.flatMap { messageCache[$0] }
        messages = cachedMessages ?? []
        loadingMessages = room != nil && cachedMessages == nil
        refreshMessageTranslations()
        previewDraft = nil
        if let account, let room, room.hasSuffix("@chatroom"), listing(.all).first(where: { $0.id == room })?.name == nil,
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

    func updatePreview(_ text: String, edit: DraftEdit?, in room: String) {
        guard !sending, selection == room, var updated = confirmedPreview else { return }
        updated.update(text, edit: edit)
        if updated != previewDraft { previewDraft = updated }
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
        let korean = Language.korean.rawValue
        // A short Korean sentence with a Latin term can be misidentified as a European language.
        let code = Self.nameSource(prose) == korean ? korean : NLLanguageRecognizer.dominantLanguage(for: prose)?.rawValue
        if !prose.contains(where: \.isLetter) || (!mixed && code?.split(separator: "-").first == target.rawValue.split(separator: "-").first) {
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
            status = UIMessage("번역 완료 · 번역문을 수정한 뒤 Enter로 전송할 수 있습니다.")
        }
    }

    private var confirmedPreview: MessageDraft? {
        guard let previewSource, composerDraft == previewSource.draft, selection == previewSource.room,
              outgoing == previewSource.language else { return nil }
        return previewDraft
    }

    func submitComposer() async {
        guard canSend else { return }
        if shouldTranslateOnEnter { translate(draft) }
        else { await send() }
    }

    func send() async {
        guard canSend, let account, let selection else { return }
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
        message.isRecalled || isRecalledMessage(id: message.id)
    }

    func isRecalledMessage(id: String) -> Bool { confirmedRecalls.contains(id) }

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
                automaticTranslations[message.id] = nil
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
    @State private var showingRemovedRooms = false
    @State private var showingTranslationOptions = false
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
        .frame(minWidth: 840, minHeight: 620)
        .tint(MacWeChatStyle.action)
        .task { await model.start(); await model.poll() }
        .translationTask(model.config) { [generation = model.translationGeneration] session in
            await model.runTranslation(session, generation: generation)
        }
        .translationTask(model.automaticConfig) { [generation = model.automaticTranslationGeneration] session in
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
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(MacWeChatStyle.accent)
                .frame(width: 72, height: 72)
                .background(MacWeChatStyle.selection, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)
            Text(language.label("위챗 번역")).font(.system(size: 27, weight: .semibold))
            if let qr = model.qr {
                Image(nsImage: qr).resizable().interpolation(.none).scaledToFit().frame(width: 245, height: 245)
                    .accessibilityLabel(language.label("위챗 로그인 QR 코드"))
            }
            Text(model.status.text(in: language))
                .foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.center)
            if model.loggingIn { Button(language.label("취소")) { loginTask?.cancel() } }
            else if model.ready {
                Button(language.label("QR 로그인")) { loginTask = Task { await model.login() } }
                    .buttonStyle(.borderedProminent)
            } else { Button(language.label("다시 연결")) { Task { await model.start() } } }
        }
        .padding(32)
        .frame(width: 388)
        .background(MacWeChatStyle.panel, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(MacWeChatStyle.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacWeChatStyle.surface)
        .overlay(alignment: .topTrailing) { languageSettings.padding(16) }
    }

    private var navigationRail: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MacWeChatStyle.accent)
                .frame(width: 44, height: 44)
                .background(MacWeChatStyle.selection, in: Circle())
                .accessibilityHidden(true)
                .padding(.bottom, 12)
            navigationButton("대화", icon: "bubble.left.and.bubble.right", filter: .all)
            navigationButton("연락처", icon: "person", filter: .contacts)
            navigationButton("그룹", icon: "person.2", filter: .groups)
            Spacer()
            languageSettings
        }
        .padding(.vertical, 18)
        .frame(width: 68)
        .frame(maxHeight: .infinity)
        .background(MacWeChatStyle.rail)
    }

    private func navigationButton(_ label: String, icon: String, filter target: RoomFilter) -> some View {
        let selected = filter == target || target == .all && filter == .chats
        return Button(language.label(label), systemImage: icon) { filter = target }
            .labelStyle(.iconOnly)
            .buttonStyle(MacWeChatIconButton(selected: selected))
            .help(language.label(label))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var roomList: some View {
        let listed = model.listing(filter)
        let matches = listed.filter {
            search.isEmpty || $0.title(in: language).localizedCaseInsensitiveContains(search)
                || model.englishSearchAlias($0)?.localizedCaseInsensitiveContains(search) == true
                || ($0.isGroup && $0.id.localizedCaseInsensitiveContains(search))
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language.label("대화")).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(language.label("목록 새로고침"), systemImage: "arrow.clockwise") {
                    Task { await model.syncDirectoryNames() }
                }.labelStyle(.iconOnly).buttonStyle(MacWeChatIconButton())
                    .help(language.label("그룹과 연락처 다시 읽기"))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(language.label("대화 검색"), text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button(language.label("검색 지우기"), systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(MacWeChatStyle.field, in: Capsule())
            HStack(spacing: 4) {
                ForEach(RoomFilter.allCases) { item in
                    Button { filter = item } label: {
                        Text(language.label(item.rawValue))
                            .font(.system(size: 12, weight: filter == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundStyle(filter == item ? MacWeChatStyle.accent : Color.secondary)
                            .background(filter == item ? MacWeChatStyle.selection : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
            if let status = model.directoryStatus {
                Text(status.text(in: language)).font(.caption).foregroundStyle(.secondary)
            }
            if !model.removedRooms.isEmpty { removedRoomsButton }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(matches) { room in roomButton(room) }
                    if search.isEmpty, filter == .all || filter == .chats, !model.isRoomRemoved("filehelper"),
                       !listed.contains(where: { $0.id == "filehelper" }) {
                        roomButton(Room(id: "filehelper", displayName: nil, unreadCount: nil))
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
        .background(MacWeChatStyle.panel)
    }

    private var removedRoomsButton: some View {
        Button(language.label("삭제한 대화방"), systemImage: "arrow.uturn.backward") {
            showingRemovedRooms.toggle()
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showingRemovedRooms, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(language.label("삭제한 대화방")).font(.headline)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.removedRooms) { room in
                            let title = room.title(in: language)
                            HStack {
                                Text(title).lineLimit(2)
                                Spacer()
                                Button(language.label("복원")) {
                                    model.restoreRoomToList(room.id)
                                    if model.removedRooms.isEmpty { showingRemovedRooms = false }
                                }
                                .accessibilityLabel(language.label("%@ 복원", title))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(250, CGFloat(model.removedRooms.count) * 40))
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private var translationControl: some View {
        let title = language.label(model.automaticTranslationEnabled ? "자동 번역 켜짐" : "자동 번역 꺼짐")
        return Button { showingTranslationOptions.toggle() } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: "translate")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.automaticTranslationEnabled ? MacWeChatStyle.accent : Color.secondary)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(model.automaticTranslationEnabled ? MacWeChatStyle.selection : MacWeChatStyle.field, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .popover(isPresented: $showingTranslationOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(language.label("자동 번역"), isOn: $model.automaticTranslationEnabled)
                    .toggleStyle(.switch)
                Divider()
                picker("받는 메시지 번역", $model.received)
                picker("보내는 메시지 번역", $model.outgoing)
            }.padding(14)
        }
    }

    private func avatar(for room: Room, size: CGFloat = 40) -> some View {
        RoomAvatar(room: room, members: model.groupAvatarMembers[room.id] ?? [], images: model.avatarImages, size: size)
    }

    private var chats: some View {
        let selected = model.selection.map { id in
            model.listing(.all).first { $0.id == id } ?? Room(id: id, displayName: nil, unreadCount: nil)
        }
        return HStack(spacing: 0) {
            navigationRail
            Rectangle().fill(MacWeChatStyle.border).frame(width: 1)
            HSplitView {
                roomList
                conversation(selected)
            }
        }
    }

    private func conversation(_ selected: Room?) -> some View {
        let messages = model.visibleMessages
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let selected { avatar(for: selected, size: 38) }
                Text(selected?.title(in: language) ?? language.label("대화를 선택하세요"))
                    .font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let room = selected {
                    translationControl
                    Button(language.label("대화 기록 검색"), systemImage: "magnifyingglass") { showingHistorySearch.toggle() }
                        .labelStyle(.iconOnly).buttonStyle(MacWeChatIconButton())
                        .help(language.label("대화 기록 검색"))
                        .popover(isPresented: $showingHistorySearch, arrowEdge: .bottom) {
                            ChatHistorySearch(model: model, room: room.id).id(room.id)
                        }
                    if !["filehelper", "brandsessionholder"].contains(room.id) { chatInfo(room) }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .frame(minHeight: 61)
            .background(MacWeChatStyle.panel)
            Rectangle().fill(MacWeChatStyle.border).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 14) {
                        if model.loadingMessages { ProgressView(language.label("대화 불러오는 중…")).padding(.top, 28) }
                        else if messages.isEmpty, selected != nil { Text(language.label("표시할 메시지가 없습니다.")).foregroundStyle(.secondary).padding(.top, 28) }
                        if let selected {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if let date = message.date,
                                   index == 0 || messages[index - 1].date.map({ !calendar.isDate($0, inSameDayAs: date) }) == true {
                                    messageDay(date, isToday: calendar.isDateInToday(date))
                                }
                                bubble(message, in: selected)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .padding(.horizontal, 18).padding(.top, 14)
                }
                .onAppear { scroller.scrollTo("latest", anchor: .bottom) }
                .onChange(of: model.messages.last?.id) { _, _ in scroller.scrollTo("latest", anchor: .bottom) }
            }
            if let room = selected?.id { composer(room) }
            HStack {
                Text(model.status.text(in: language)).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
                if model.lastHiddenMessage != nil {
                    Button(language.label("최근 숨김 취소")) { model.undoHideMessage() }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 515, maxWidth: .infinity, maxHeight: .infinity)
        .background(MacWeChatStyle.surface)
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
            showingTranslationOptions = false
        }
    }

    private func messageDay(_ date: Date, isToday: Bool) -> some View {
        let label = isToday ? language.label("오늘")
            : date.formatted(.dateTime.year().month().day().locale(Locale(identifier: language.rawValue)))
        return Text(label)
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(MacWeChatStyle.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(MacWeChatStyle.border))
    }

    private func composer(_ room: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            }.id(room).frame(height: 66)
                .background(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 13).fill(MacWeChatStyle.field)
                    if model.draft.isEmpty {
                        Text(language.label("메시지 입력…")).font(.system(size: 14))
                            .foregroundStyle(.secondary).padding(.leading, 14).padding(.top, 9)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
            if let preview = model.preview {
                Label(language.label("%@ 번역 미리보기", model.outgoing.title), systemImage: "translate")
                    .font(.caption.weight(.semibold)).foregroundStyle(MacWeChatStyle.accent)
                MessageComposer(text: preview, editable: !model.sending, label: language.label("번역문"),
                                onEdit: { text, edit, _ in model.updatePreview(text, edit: edit, in: room) }) {
                    Task { await model.submitComposer() }
                }.id(room).frame(height: 56)
                    .background(MacWeChatStyle.selection, in: RoundedRectangle(cornerRadius: 11))
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
            HStack(spacing: 6) {
                Button(language.label("파일 첨부"), systemImage: "paperclip") { model.chooseFile() }
                    .labelStyle(.iconOnly).buttonStyle(MacWeChatIconButton()).help(language.label("파일 첨부"))
                    .disabled(model.attachments[room] != nil)
                if room.hasSuffix("@chatroom") {
                    Button(language.label("멤버 멘션"), systemImage: "at") { beginMention(in: room) }
                        .labelStyle(.iconOnly).buttonStyle(MacWeChatIconButton()).help(language.label("멤버 멘션"))
                }
                Spacer(minLength: 4)
                Text(language.label(model.shouldTranslateOnEnter
                                    ? "Enter: 번역 · Shift+Enter: 줄바꿈" : "Enter: 전송 · Shift+Enter: 줄바꿈"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(language.label("초안 번역"), systemImage: "translate") { model.translate(model.draft) }
                    .labelStyle(.iconOnly).buttonStyle(MacWeChatIconButton(selected: model.preview != nil))
                    .help(language.label("초안 번역")).disabled(model.draft.isEmpty || model.translating || model.sending)
                Button { Task { await model.send() } } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 37, height: 37)
                        .background(MacWeChatStyle.action, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(model.canSend ? 1 : 0.45)
                .disabled(!model.canSend)
                .accessibilityLabel(language.label("전송")).help(language.label("전송"))
            }
        }
        .padding(10)
        .background(MacWeChatStyle.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(MacWeChatStyle.border))
        .padding(.horizontal, 14)
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
            .buttonStyle(MacWeChatIconButton())
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
            .buttonStyle(MacWeChatIconButton())
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
                    Toggle(language.label("자동 번역"), isOn: $model.automaticTranslationEnabled)
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
        let summary = model.latestSummary(for: room)
        let latest = summary == nil ? model.latestMessage(in: room.id) : nil
        let preview = summary.map { summaryPreview($0, in: room) } ?? latest.map { quotePreview($0, in: room.id) }
        let unread = model.unreadCount(for: room)
        return Button { model.select(room.id) } label: {
            HStack(spacing: 9) {
                avatar(for: room)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let preview {
                        Text(preview).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    if let date = summary?.date ?? latest?.date {
                        Text(date, format: .dateTime.hour().minute().locale(Locale(identifier: language.rawValue)))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                    if unread > 0 {
                        Text(unread.formatted()).font(.caption2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(MacWeChatStyle.action, in: Capsule())
                            .accessibilityLabel(language.label("읽지 않은 메시지 %@개", unread.formatted()))
                    }
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
            .background(model.selection == room.id ? MacWeChatStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(model.selection == room.id ? .isSelected : [])
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
            Button(role: .destructive) { model.removeRoomFromList(room) } label: {
                Label(language.label("대화 목록에서 삭제"), systemImage: "trash")
            }
            .disabled(!model.canRemoveRoom(room.id))
        }
    }

    private func bubble(_ message: Message, in room: Room) -> some View {
        let recalled = model.isRecalled(message)
        let showAvatar = !message.outgoing && message.hasSender && !recalled
        let showSender = room.isGroup && showAvatar
        return HStack(alignment: .top, spacing: 7) {
            if message.outgoing { Spacer(minLength: 52) }
            if showSender { groupSenderAvatar(message.senderId, in: room.id) }
            else if showAvatar { avatar(for: room, size: 34) }
            VStack(alignment: .leading, spacing: 4) {
                if showSender {
                    Text(model.groupSenderName(message.senderId, in: room.id))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                messageContent(message, recalled: recalled)
            }
            .contextMenu {
                messageActions(message, in: room.id)
            }
            Menu {
                messageActions(message, in: room.id)
            } label: {
                Label(language.label("메시지 메뉴"), systemImage: "ellipsis").labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(language.label("메시지 메뉴"))
            .padding(.top, showSender ? 21 : 4)
            if !message.outgoing { Spacer(minLength: 52) }
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
        MacWeChatAvatar(size: 34) {
            ZStack {
                MacWeChatStyle.field
                if let id, let image = model.avatarImages[id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
        }
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

    private func summaryPreview(_ summary: RoomMessageSummary, in room: Room) -> String {
        if model.isRecalledMessage(id: summary.id) { return language.label("회수된 메시지") }
        let author = summary.direction == "outgoing" ? language.label("나") : room.isGroup ? summary.senderName : nil
        return author.map { "\($0) · \(summary.text)" } ?? summary.text
    }

    private func messageContent(_ message: Message, recalled: Bool) -> some View {
        let manualTranslation = model.translations[message.id]
        let translation = manualTranslation ?? model.automaticTranslations[message.id]
        return MacWeChatBubble(outgoing: message.outgoing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    messageBody(message, recalled: recalled)
                        .font(.system(size: 14)).layoutPriority(1)
                    if let date = message.date {
                        Text(date, format: .dateTime.hour().minute().locale(Locale(identifier: language.rawValue)))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                }
                if !recalled, let translation {
                    Divider()
                    Label(language.label(manualTranslation == nil ? "%@ 자동 번역" : "%@ 번역", model.received.title),
                          systemImage: "translate")
                        .font(.caption.weight(.semibold)).foregroundStyle(MacWeChatStyle.accent)
                    Text(translation).font(.system(size: 14)).textSelection(.enabled)
                } else if !recalled, message.hasTranslatableText, let body = message.body {
                    Button(language.label("번역"), systemImage: "translate") { model.translate(body, message: message.id) }
                        .font(.caption).buttonStyle(.link).disabled(model.translating)
                }
                if !recalled, let quote = message.quote {
                    let text = quote.state == "recalled" ? language.label("회수된 메시지")
                        : quote.embeddedText ?? language.label("인용한 메시지")
                    Divider()
                    Label(quote.senderName.map { "\($0) · \(text)" } ?? text, systemImage: "quote.bubble")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 455, alignment: message.outgoing ? .trailing : .leading)
    }

    @ViewBuilder
    private func messageBody(_ message: Message, recalled: Bool) -> some View {
        if recalled {
            Text(language.label("회수된 메시지")).foregroundStyle(.secondary)
        } else if let attachment = message.attachmentLabelKey {
            VStack(alignment: .leading, spacing: 6) {
                Label(message.body ?? language.label(attachment), systemImage: "doc").textSelection(.enabled)
                Button(language.label(model.downloading.contains(message.id) ? "가져오는 중…" : "첨부파일 저장…"),
                       systemImage: "arrow.down.to.line") {
                    Task { await model.saveAttachment(message) }
                }.buttonStyle(.link).disabled(model.downloading.contains(message.id))
            }
        } else {
            Text(message.body ?? language.label("[첨부 또는 시스템 메시지]")).textSelection(.enabled)
        }
    }

    private func picker(_ label: String, _ selection: Binding<Language>) -> some View {
        Picker(language.label(label), selection: selection) { ForEach(Language.allCases) { Text($0.title).tag($0) } }.fixedSize()
    }
}

@main
struct NativeTranslatorApp: App {
    @StateObject private var model = ChatModel()
    private let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "WeChat Native Translator"

    var body: some Scene {
        Window(title, id: "wechat-native-translator") {
            ChatView(model: model)
                .background(MinimizeOnClose())
        }
        .defaultSize(width: 1100, height: 740)
    }
}

private struct MinimizeOnClose: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let closeButton = window.standardWindowButton(.closeButton) else { return }
            closeButton.target = window
            closeButton.action = #selector(NSWindow.miniaturize(_:))
        }
    }
}
