import Foundation
import UniformTypeIdentifiers

struct Page<Item: Decodable>: Decodable { let items: [Item]; let nextCursor: String? }
struct Account: Decodable { let id: String; let authenticated: Bool? }
struct RoomAvatarMember: Decodable, Identifiable, Equatable { let id: String }
struct RoomMessageSummary: Decodable, Equatable {
    let id: String
    let text: String
    let createdAt: String?
    let direction: String?
    let senderName: String?

    var date: Date? { messageDate(createdAt) }
}

struct Room: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String?
    let unreadCount: Int?
    let readStateVersion: String?
    let avatarMembers: [RoomAvatarMember]?
    let lastMessage: RoomMessageSummary?

    init(id: String, displayName: String?, unreadCount: Int?, readStateVersion: String? = nil,
         avatarMembers: [RoomAvatarMember]? = nil, lastMessage: RoomMessageSummary? = nil) {
        self.id = id
        self.displayName = displayName
        self.unreadCount = unreadCount
        self.readStateVersion = readStateVersion
        self.avatarMembers = avatarMembers
        self.lastMessage = lastMessage
    }

    var isGroup: Bool { id.hasSuffix("@chatroom") }
    var name: String? {
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != id, !name.hasSuffix("@chatroom") else { return nil }
        return name
    }
    func title(in language: Language) -> String {
        if id == "filehelper" { return language.label("파일 전송") }
        if id == "brandsessionholder" { return language.label("서비스 계정") }
        if let name { return name }
        if isGroup { return language.label("이름 미확인 그룹") }
        return id
    }

    func withName(_ name: String) -> Room {
        Room(id: id, displayName: name, unreadCount: unreadCount, readStateVersion: readStateVersion,
             avatarMembers: avatarMembers, lastMessage: lastMessage)
    }
}
struct Contact: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String?
    let nickname: String?
    let remark: String?
    var room: Room {
        let name = [remark, displayName, nickname].compactMap { $0 }
            .lazy.map { Room(id: id, displayName: $0, unreadCount: nil) }.compactMap(\.name).first
        return Room(id: id, displayName: name, unreadCount: nil)
    }
}
struct GroupRoom: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String?
    let name: String?
    let remark: String?

    var room: Room {
        let names = [remark, displayName, name].compactMap { $0 }
        let displayName = names.lazy.map { Room(id: id, displayName: $0, unreadCount: nil) }.compactMap(\.name).first
        return Room(id: id, displayName: displayName, unreadCount: nil)
    }
}
struct Message: Decodable, Identifiable, Equatable {
    struct Recall: Decodable, Equatable { let replacementText: String? }
    struct Quote: Decodable, Equatable {
        let senderName: String?
        let embeddedText: String?
        let state: String?
    }

    let id: String
    let type: Int
    let direction: String?
    let body: String?
    let appMessageType: Int?
    let senderId: String?
    let threadId: String?
    let serverId: String?
    let createdAt: String?
    let recall: Recall?
    let quote: Quote?
    var outgoing: Bool { direction == "outgoing" }
    var date: Date? { messageDate(createdAt) }
    var hasSender: Bool { type < 10000 && (direction == "incoming" || senderId != nil) }
    var isRecalled: Bool { recall != nil }
    var confirmedServerID: String? {
        guard let serverId, let value = UInt64(serverId), value > 0, String(value) == serverId else { return nil }
        return serverId
    }
    var hasTranslatableText: Bool { !isRecalled && (type == 1 || (type == 49 && appMessageType == 57)) }
    var quoteReference: TextSendRequest.Quote? {
        let supported = switch type {
        case 1, 3, 34, 42, 43, 47, 48: true
        case 49: appMessageType.map { [1, 3, 4, 5, 6, 8, 19, 51, 57, 87].contains($0) } ?? false
        default: false
        }
        guard !isRecalled, supported, let confirmedServerID else { return nil }
        return .init(messageId: id, serverId: confirmedServerID)
    }
    var attachmentLabelKey: String? {
        guard !isRecalled else { return nil }
        return switch type {
        case 3: "사진"
        case 34: "음성 메시지"
        case 43, 62: "동영상"
        case 47: "스티커"
        case 49 where appMessageType == 6: "파일"
        default: nil
        }
    }
}

private func messageDate(_ timestamp: String?) -> Date? {
    guard let timestamp else { return nil }
    return (try? Date(timestamp, strategy: .iso8601))
        ?? (try? Date(timestamp, strategy: .iso8601.time(includingFractionalSeconds: true)))
}
struct Operation: Decodable {
    struct Result: Decodable {
        let qrAvailable: Bool?
        let qrGeneration: Int?
        let reason: String?
        let errorCode: String?
        let action: String?
        let targetId: String?
        let memberOutcome: String?
        let messageId: String?
        let threadId: String?
        let serverId: String?
        let status: String?
    }
    let id: String
    let state: String
    let result: Result?
}
struct Send: Decodable { let id: String; let destination: String; let state: String; let errorCode: String? }

struct MediaAsset: Decodable {
    let id: String
    let accountId: String
    let messageId: String?
    let state: String
    let variant: String
    let filename: String?
    let byteLength: Int?
    let contentType: String?
    let jobId: String?
    let reason: String?

    func saveName(in language: Language) -> String {
        let safe = (filename ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "_")
        if !safe.isEmpty && safe != "." && safe != ".." { return safe }
        return language.label("첨부파일") + (contentType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }.map { "." + $0 } ?? "")
    }
}

struct MediaJob: Decodable {
    let id: String
    let accountId: String
    let kind: String
    let state: String
    let sourceId: String?
    let threadId: String?
    let assetId: String?
    let reason: String?
    let retryable: Bool
    var active: Bool { state == "queued" || state == "running" }
}

enum AttachmentError: AppDisplayError {
    case invalidFile, unavailable(String?)

    var displayMessage: UIMessage {
        switch self {
        case .invalidFile: UIMessage("비어 있지 않은 512 MiB 이하의 일반 파일을 선택하세요.")
        case .unavailable(let reason):
            switch reason {
            case "expired", "media_expired": UIMessage("위챗에서 이 첨부파일의 보관 기간이 만료되었습니다.")
            case "transport_unavailable", "media_disconnected": UIMessage("위챗 파일 서버에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.")
            case "download_pending": UIMessage("아직 첨부파일을 가져오는 중입니다. 잠시 후 저장을 다시 눌러 주세요.")
            default: UIMessage("이 첨부파일을 가져올 수 없습니다.%@", reason.map { " (\($0))" } ?? "")
            }
        }
    }
}

enum ConnectionError: AppDisplayError {
    case missingEngine, unavailable, response(Int, String?), invalidResponse

    var displayMessage: UIMessage {
        switch self {
        case .missingEngine: UIMessage("독립 연결 엔진이 설치되어 있지 않습니다.")
        case .unavailable: UIMessage("로컬 위챗 연결 엔진을 시작하지 못했습니다.")
        case .invalidResponse: UIMessage("위챗 연결 엔진에서 응답을 읽지 못했습니다.")
        case let .response(code, reason): UIMessage("위챗 연결 요청 실패 (%@%@)", String(code), reason.map { ", " + $0 } ?? "")
        }
    }
}

@MainActor
final class Backend {
    private var process: Process?
    private var endpoint: String?
    private var token = ""
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func appDataDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("WeChat Native Translator", isDirectory: true)
    }

    func start() async throws {
        if process?.isRunning == true { return }
        guard let engine = Bundle.main.url(forAuxiliaryExecutable: "wx") else { throw ConnectionError.missingEngine }
        let root = try Self.appDataDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let tokenFile = root.appendingPathComponent("local-api-token")
        if !FileManager.default.fileExists(atPath: tokenFile.path) {
            let newToken = UUID().uuidString + UUID().uuidString
            guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data(newToken.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else { throw ConnectionError.unavailable }
        }
        token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectionError.unavailable }
        let port = Int.random(in: 38000...59999)
        endpoint = "http://127.0.0.1:\(port)/v1"
        let child = Process()
        child.executableURL = engine
        child.arguments = ["--data-dir", root.appendingPathComponent("profile").path,
                           "--token-file", tokenFile.path, "--listen", "127.0.0.1:\(port)", "serve"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<35 {
            if child.isRunning, (try? await data("/status")) != nil { return }
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(180))
        }
        stop()
        throw ConnectionError.unavailable
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        endpoint = nil
    }

    func accounts() async throws -> [Account] { try await decode(Page<Account>.self, "/accounts").items }

    func newAccount() async throws -> Account {
        try await decode(Account.self, "/accounts", method: "POST", body: ["id": "personal"])
    }

    func login(_ account: String) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/auth/login", method: "POST", body: [:], key: UUID().uuidString)
    }

    func operation(_ account: String, _ id: String) async throws -> Operation {
        try await decode(Operation.self, operationPath(account, id))
    }

    func cancelLogin(_ account: String, _ id: String) async {
        _ = try? await data(operationPath(account, id), method: "DELETE")
    }

    func qr(_ account: String, _ id: String, generation: Int) async throws -> Data {
        let bytes = try await data(operationPath(account, id) + "/qr?generation=\(generation)")
        guard bytes.count <= 1_048_576, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ConnectionError.invalidResponse
        }
        return bytes
    }

    func rooms(_ account: String) async throws -> [Room] {
        try await allPages(Room.self, "/accounts/\(part(account))/threads")
    }

    func contacts(_ account: String) async throws -> [Contact] {
        try await allPages(Contact.self, "/accounts/\(part(account))/contacts")
    }

    func wechatContactName(_ account: String, id: String) async throws -> String {
        struct Lookup: Decodable {
            struct Item: Decodable { let id: String; let displayName: String }
            let items: [Item]
            let results: [Int]
        }
        let body = try JSONEncoder().encode(["ids": [id]])
        let bytes = try await data("/accounts/\(part(account))/contacts/lookup", method: "POST", encodedBody: body)
        let result = try JSONDecoder().decode(Lookup.self, from: bytes)
        guard result.results == [0], result.items.count == 1, let contact = result.items.first,
              contact.id == id, !contact.displayName.isEmpty else { throw ConnectionError.invalidResponse }
        return contact.displayName
    }

    func groups(_ account: String) async throws -> [GroupRoom] {
        try await allPages(GroupRoom.self, "/accounts/\(part(account))/groups")
    }

    func refreshGroup(_ account: String, _ group: String) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/groups/\(part(group))/refresh", method: "POST", body: [:])
    }

    func groupMembers(_ account: String, _ group: String) async throws -> [RoomAvatarMember] {
        try await decode(Page<RoomAvatarMember>.self, "/accounts/\(part(account))/groups/\(part(group))/members?limit=9").items
    }

    func groupRoster(_ account: String, _ group: String) async throws -> [GroupMember] {
        try await allPages(GroupMember.self, "/accounts/\(part(account))/groups/\(part(group))/members")
    }

    func addGroupMembers(_ account: String, group: String, members: [String], key: String) async throws -> Operation {
        let path = "/accounts/\(part(account))/groups/\(part(group))/members"
        let body = try JSONEncoder().encode(["members": members])
        let bytes = try await data(path, method: "POST", key: key, encodedBody: body)
        return try JSONDecoder().decode(Operation.self, from: bytes)
    }

    func refreshGroupMembers(_ account: String, _ group: String) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/groups/\(part(group))/members/refresh", method: "POST", body: [:])
    }

    func avatar(_ account: String, _ id: String) async throws -> Data {
        try await data("/accounts/\(part(account))/avatars/\(part(id))", imageResponse: true)
    }

    func refreshAvatar(_ account: String, _ id: String, group: String?) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/avatars/\(part(id))/refresh",
                         method: "POST", body: group.map { ["roomId": $0] } ?? [:])
    }

    func syncGroups(_ account: String) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/group-sync", method: "POST", body: [:])
    }

    func syncContacts(_ account: String) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/contact-sync", method: "POST", body: [:])
    }

    func messages(_ account: String, _ room: String) async throws -> [Message] {
        try await decode(Page<Message>.self, "/accounts/\(part(account))/threads/\(part(room))/messages?limit=80").items.reversed()
    }

    func searchMessages(_ account: String, room: String, query: String, cursor: String?) async throws -> Page<Message> {
        let suffix = cursor.map { "&cursor=" + part($0) } ?? ""
        return try await decode(Page<Message>.self,
                                "/accounts/\(part(account))/threads/\(part(room))/messages?limit=40&search=\(part(query))" + suffix)
    }

    func recall(_ account: String, message: String, serverID: String, key: String) async throws -> Operation {
        try await decode(Operation.self, "/accounts/\(part(account))/messages/\(part(message))/recall",
                         method: "POST", body: ["serverId": serverID], key: key)
    }

    func thread(_ account: String, _ room: String) async throws -> Room {
        try await decode(Room.self, "/accounts/\(part(account))/threads/\(part(room))")
    }

    func markRead(_ account: String, room: String, version: String) async throws {
        struct Receipt: Decodable { let threadId: String; let version: String }
        let receipt = try await decode(Receipt.self, "/accounts/\(part(account))/threads/\(part(room))/read-state",
                                       method: "POST", body: ["expectedVersion": version])
        guard receipt.threadId == room, !receipt.version.isEmpty else { throw ConnectionError.invalidResponse }
    }

    func send(_ account: String, request: TextSendRequest, key: String) async throws -> Send {
        let body = try JSONEncoder().encode(request)
        let bytes = try await data("/accounts/\(part(account))/sends", method: "POST", key: key, encodedBody: body)
        return try JSONDecoder().decode(Send.self, from: bytes)
    }

    func checkSend(_ account: String, _ id: String) async throws -> Send {
        try await decode(Send.self, "/accounts/\(part(account))/sends/\(part(id))")
    }

    func upload(_ account: String, file: URL) async throws -> String {
        struct Source: Decodable { let id: String }
        let boundary = UUID().uuidString
        let body = try await Task.detached(priority: .userInitiated) { try Self.multipart(file, boundary: boundary) }.value
        defer { try? FileManager.default.removeItem(at: body.deletingLastPathComponent()) }
        var request = try authorizedRequest("/accounts/\(part(account))/uploads", method: "POST")
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.upload(for: request, fromFile: body)
        _ = try checked(response, bytes)
        return try JSONDecoder().decode(Source.self, from: bytes).id
    }

    func sendFile(_ account: String, room: String, source: String, key: String) async throws -> MediaJob {
        try await decode(MediaJob.self, "/accounts/\(part(account))/sends", method: "POST",
                         body: ["threadId": room, "sourceId": source, "kind": "file"], key: key)
    }

    func mediaJob(_ account: String, _ id: String) async throws -> MediaJob {
        try await decode(MediaJob.self, "/accounts/\(part(account))/jobs/\(part(id))")
    }

    func waitForMedia(_ account: String, initial: MediaJob) async throws -> MediaJob {
        guard initial.accountId == account else { throw ConnectionError.invalidResponse }
        var job = initial
        let deadline = ContinuousClock.now + .seconds(150)
        while job.active && ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            job = try await mediaJob(account, initial.id)
            guard job.accountId == account, job.id == initial.id, job.kind == initial.kind else { throw ConnectionError.invalidResponse }
        }
        return job
    }

    func attachment(_ account: String, message: String) async throws -> MediaAsset {
        struct Assets: Decodable { let items: [MediaAsset] }
        let base = "/accounts/\(part(account))"
        let path = base + "/messages/\(part(message))"
        let assets = try await decode(Assets.self, path + "/media").items
        guard assets.allSatisfy({ $0.accountId == account && $0.messageId == message }) else { throw ConnectionError.invalidResponse }
        let preference = ["original", "standard", "normal", "encoded", "thumbnail"]
        let sorted = assets.sorted { (preference.firstIndex(of: $0.variant) ?? 99) < (preference.firstIndex(of: $1.variant) ?? 99) }
        guard let asset = sorted.first(where: { ["available", "pending", "failed"].contains($0.state) }) else {
            throw AttachmentError.unavailable(sorted.first?.reason ?? sorted.first?.state)
        }
        if asset.state == "available" { return asset }
        var existing: MediaJob?
        if let id = asset.jobId { existing = try await mediaJob(account, id) }
        var job: MediaJob
        if let existing {
            job = existing
        } else {
            job = try await decode(MediaJob.self, path + "/media-transfers", method: "POST",
                                   body: ["messageId": message, "assetId": asset.id, "quality": asset.variant])
        }
        // The engine bounds retries for the same attachment. Never create a new
        // job just to bypass that limit, or retry a file known to have expired.
        for attempt in 0...2 {
            guard job.kind == "download", job.assetId == asset.id else { throw ConnectionError.invalidResponse }
            job = try await waitForMedia(account, initial: job)
            guard attempt < 2, !job.active, job.retryable else { break }
            if let reason = job.reason, !["transport_unavailable", "media_disconnected", "worker_interrupted", "media_worker_stopping"].contains(reason) { break }
            try await Task.sleep(for: .seconds(attempt + 1))
            job = try await decode(MediaJob.self, base + "/jobs/\(part(job.id))/retry", method: "POST", body: [:])
        }
        guard job.state == "available" else { throw AttachmentError.unavailable(job.active ? "download_pending" : job.reason ?? job.state) }
        let result = try await decode(MediaAsset.self, base + "/media/\(part(asset.id))")
        guard result.id == asset.id, result.accountId == account, result.messageId == message,
              result.state == "available" else { throw ConnectionError.invalidResponse }
        return result
    }

    func save(_ asset: MediaAsset, to destination: URL) async throws {
        var request = try authorizedRequest("/accounts/\(part(asset.accountId))/media/\(part(asset.id))/content")
        request.timeoutInterval = 120
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try checked(response)
        let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let bytes, bytes > 0, asset.byteLength == nil || asset.byteLength == bytes else { throw ConnectionError.invalidResponse }
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: directory) }
            let copy = directory.appendingPathComponent("download")
            try manager.moveItem(at: temporary, to: copy)
            if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: copy) }
            else { try manager.moveItem(at: copy, to: destination) }
        }.value
    }

    private nonisolated static func multipart(_ file: URL, boundary: String) throws -> URL {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let name = file.lastPathComponent
        let maxBytes = 512 * 1024 * 1024
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let expected = values.fileSize, expected > 0, expected <= maxBytes,
              !name.isEmpty, name.utf8.count <= 255,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\r\n")) == nil else { throw AttachmentError.invalidFile }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? manager.removeItem(at: directory) } }
        let body = directory.appendingPathComponent("upload")
        guard manager.createFile(atPath: body.path, contents: nil) else { throw ConnectionError.unavailable }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: body)
        defer { try? output.close() }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let quotedName = name.replacingOccurrences(of: "\"", with: "\\\"")
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(quotedName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        var written = 0
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            written += bytes.count
            guard written <= expected else { throw AttachmentError.invalidFile }
            try output.write(contentsOf: bytes)
        }
        guard written == expected else { throw AttachmentError.invalidFile }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        completed = true
        return body
    }

    private func allPages<Item: Decodable & Identifiable>(_ type: Item.Type, _ path: String) async throws -> [Item] {
        var items: [Item] = []
        var seenItems: Set<Item.ID> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let suffix = cursor.map { "&cursor=" + part($0) } ?? ""
            let page = try await decode(Page<Item>.self, path + "?limit=200" + suffix)
            items.append(contentsOf: page.items.filter { seenItems.insert($0.id).inserted })
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw ConnectionError.invalidResponse }
        } while cursor != nil
        return items
    }

    private func operationPath(_ account: String, _ id: String) -> String {
        "/accounts/\(part(account))/operations/\(part(id))"
    }

    private func part(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET",
                                      body: [String: String]? = nil, key: String? = nil) async throws -> T {
        try JSONDecoder().decode(type, from: await data(path, method: method, body: body, key: key))
    }

    private func data(_ path: String, method: String = "GET", body: [String: String]? = nil,
                      key: String? = nil, imageResponse: Bool = false, encodedBody: Data? = nil) async throws -> Data {
        var request = try authorizedRequest(path, method: method)
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let payload = try encodedBody ?? body.map({ try JSONEncoder().encode($0) }) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
        }
        let (bytes, raw) = try await session.data(for: request)
        let response = try checked(raw, bytes)
        if imageResponse {
            guard response.mimeType?.hasPrefix("image/") == true, bytes.count <= 16 * 1024 * 1024 else {
                throw ConnectionError.invalidResponse
            }
        }
        return bytes
    }

    private func authorizedRequest(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let endpoint, let url = URL(string: endpoint + path) else { throw ConnectionError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func checked(_ raw: URLResponse, _ bytes: Data = Data()) throws -> HTTPURLResponse {
        guard let response = raw as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable {
                struct Detail: Decodable { let code: String }
                let error: Detail
            }
            throw ConnectionError.response(response.statusCode, (try? JSONDecoder().decode(Failure.self, from: bytes))?.error.code)
        }
        return response
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
