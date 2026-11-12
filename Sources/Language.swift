import Foundation

enum Language: String, CaseIterable, Identifiable {
    case korean = "ko", english = "en", chinese = "zh-Hans"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        case .chinese: "简体中文"
        }
    }

    static func preferred(from identifiers: [String] = Locale.preferredLanguages) -> Language {
        for identifier in identifiers {
            switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            case "ko": return .korean
            case "en": return .english
            case "zh": return .chinese
            default: continue
            }
        }
        return .english
    }

    private static let bundles = Dictionary(uniqueKeysWithValues: allCases.compactMap { language in
        Bundle.main.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)).map { (language, $0) }
    })

    func label(_ key: String, _ arguments: String...) -> String {
        format(key, arguments)
    }

    fileprivate func format(_ key: String, _ arguments: [String]) -> String {
        let template = Self.bundles[self]?.localizedString(forKey: key, value: key, table: nil) ?? key
        return arguments.isEmpty ? template : String(format: template, locale: Locale(identifier: rawValue), arguments: arguments)
    }
}

struct UIMessage {
    let key: String
    private let arguments: [String]
    private let error: Error?

    init(_ key: String, _ arguments: String...) {
        self.key = key
        self.arguments = arguments
        self.error = nil
    }

    init(error: Error, prefix: String = "") {
        self.key = prefix
        self.arguments = []
        self.error = error
    }

    func text(in language: Language) -> String {
        guard let error else { return language.format(key, arguments) }
        let detail = (error as? AppDisplayError)?.displayMessage.text(in: language) ?? error.localizedDescription
        return key.isEmpty ? detail : language.label(key, detail)
    }
}

protocol AppDisplayError: LocalizedError {
    var displayMessage: UIMessage { get }
}

extension AppDisplayError {
    var errorDescription: String? { displayMessage.text(in: .preferred()) }
}
