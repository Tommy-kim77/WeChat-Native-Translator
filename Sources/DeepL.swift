import Foundation
import Security

enum TranslationProvider: String, CaseIterable, Identifiable {
    case apple, deepL

    var id: String { rawValue }
    var title: String { self == .apple ? "Apple" : "DeepL" }
}

enum DeepLError: AppDisplayError {
    case missingKey, invalidKey, keychain, quota, rateLimit, network, oversized, response(Int), invalidResponse

    var displayMessage: UIMessage {
        switch self {
        case .missingKey: UIMessage("언어 설정에서 DeepL API 키를 추가하세요.")
        case .invalidKey: UIMessage("DeepL API 키를 확인해 주세요.")
        case .keychain: UIMessage("macOS 키체인에 접근할 수 없습니다.")
        case .quota: UIMessage("DeepL API 사용 한도에 도달했습니다.")
        case .rateLimit: UIMessage("DeepL 요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.")
        case .network: UIMessage("DeepL에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.")
        case .oversized: UIMessage("이 메시지는 DeepL로 번역하기에 너무 깁니다.")
        case .response(let code): UIMessage("DeepL 요청에 실패했습니다. (%@)", String(code))
        case .invalidResponse: UIMessage("DeepL 번역 응답을 읽을 수 없습니다.")
        }
    }

    var pausesAutomaticTranslation: Bool {
        switch self {
        case .invalidKey, .quota, .rateLimit, .network: true
        default: false
        }
    }
}

enum DeepLKeychain {
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.local.wechat.native-translator",
         kSecAttrAccount as String: "DeepL API"]
    }

    static func load() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw DeepLError.keychain }
        return key
    }

    static func save(_ key: String) throws {
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(identity as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            let item = identity.merging(value) { _, updated in updated }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DeepLError.keychain }
        } else if status != errSecSuccess {
            throw DeepLError.keychain
        }
    }

    static func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeepLError.keychain }
    }
}

struct DeepLClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    func validateKey(_ key: String) async throws {
        guard !key.isEmpty, key.utf8.count <= 512,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw DeepLError.invalidKey }
        _ = try await request("usage", key: key)
    }

    func translate(_ text: String, source: String?, target: Language, key: String) async throws -> String {
        struct Request: Encodable {
            let text: [String]
            let source_lang: String?
            let target_lang: String
        }
        struct Response: Decodable {
            struct Result: Decodable { let text: String }
            let translations: [Result]
        }
        let sourceCode = source?.split(separator: "-").first.map { $0.uppercased() }
        let body = try JSONEncoder().encode(Request(text: [text], source_lang: sourceCode,
                                                     target_lang: target == .english ? "EN-US" : target.rawValue.uppercased()))
        guard body.count <= 128 * 1024 else { throw DeepLError.oversized }
        let data = try await request("translate", key: key, body: body)
        guard let result = try? JSONDecoder().decode(Response.self, from: data), result.translations.count == 1,
              let translated = result.translations.first?.text, !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepLError.invalidResponse
        }
        return translated
    }

    private func request(_ path: String, key: String, body: Data? = nil) async throws -> Data {
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/\(path)") else { throw DeepLError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let raw: URLResponse
        do { (data, raw) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw DeepLError.network
        }
        guard let response = raw as? HTTPURLResponse else { throw DeepLError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw DeepLError.invalidKey
        case 429: throw DeepLError.rateLimit
        case 456: throw DeepLError.quota
        default: throw DeepLError.response(response.statusCode)
        }
    }
}
