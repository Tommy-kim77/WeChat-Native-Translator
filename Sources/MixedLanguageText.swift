import Foundation

struct MixedLanguageText: Hashable {
    private struct Part: Hashable {
        let text: String
        let language: Language?
    }

    private let parts: [Part]

    private static let words = try! NSRegularExpression(pattern:
        #"@[^@\r\n\u2005]+\u2005|https?://[^\s<>]+|[\p{Latin}0-9_]+(?:[.'’/+\-][\p{Latin}0-9_]+)*|\p{Hangul}+|\p{Han}+|[\p{Hiragana}\p{Katakana}]+"#)
    private static let englishCue: Set<String> = ["hi", "hello", "hey", "please", "thanks", "thank", "yes", "no", "sorry", "can", "could", "did", "have", "how", "when", "what", "check"]

    init?(_ text: String) {
        let raw = text as NSString
        let matches = Self.words.matches(in: text, range: NSRange(location: 0, length: raw.length))
        let words = matches.map { raw.substring(with: $0.range) }
        // Han characters in Japanese are not necessarily Chinese.
        guard !words.contains(where: { $0.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil }) else { return nil }
        var languages = words.map(Self.language)
        var start = 0
        while start < languages.count {
            guard languages[start] == .english else { start += 1; continue }
            var end = start + 1
            while end < languages.count, languages[end] == .english { end += 1 }
            if end - start < 3, !words[start..<end].contains(where: { Self.englishCue.contains($0.lowercased()) }) {
                for index in start..<end { languages[index] = nil }
            }
            start = end
        }
        guard Set(languages.compactMap { $0 }).count > 1 else { return nil }

        var pieces: [Part] = []
        if let first = matches.first, first.range.location > 0 {
            pieces.append(Part(text: raw.substring(to: first.range.location), language: nil))
        }
        for index in matches.indices {
            let start = matches[index].range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : raw.length
            let value = raw.substring(with: NSRange(location: start, length: end - start))
            let language = languages[index]
            if let previous = pieces.last, previous.language == language {
                pieces[pieces.count - 1] = Part(text: previous.text + value, language: language)
            } else {
                pieces.append(Part(text: value, language: language))
            }
        }
        parts = pieces
    }

    func translated(to target: Language, using translate: (String, Language) async throws -> String) async throws -> String {
        var result = ""
        for part in parts {
            guard let source = part.language, source != target else { result += part.text; continue }
            let body = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = part.text.range(of: body), !body.isEmpty else { result += part.text; continue }
            let translated = try await translate(body, source).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { throw ConnectionError.invalidResponse }
            result += String(part.text[..<range.lowerBound]) + translated + String(part.text[range.upperBound...])
        }
        return result
    }

    private static func language(of word: String) -> Language? {
        if word.hasPrefix("@") || word.hasPrefix("https://") || word.hasPrefix("http://") { return nil }
        if word.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil { return .korean }
        if word.range(of: #"\p{Han}"#, options: .regularExpression) != nil { return .chinese }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty, !word.contains(where: \.isNumber) else { return nil }
        if englishCue.contains(word.lowercased()) { return .english }
        // Capitalized names and model identifiers commonly appear inside Korean and Chinese messages.
        guard word.first?.isUppercase != true || letters.count == 1 && word == "I" else { return nil }
        return .english
    }
}
