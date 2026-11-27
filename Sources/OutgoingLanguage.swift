import Foundation

/// Composer policy for the three supported outgoing languages. Short Latin input is English;
/// statistical language detection frequently identifies "OK", "Hi" and "Invoice" incorrectly.
enum OutgoingLanguage {
    private static let protectedText = try! NSRegularExpression(
        pattern: #"https?://[^\s<>]+|www\.[^\s<>]+|@[^@\r\n\u2005]+\u2005"#, options: .caseInsensitive)
    private static let words = try! NSRegularExpression(pattern:
        #"[A-Za-z0-9_]+(?:[.'’/+\-][A-Za-z0-9_]+)*|[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]+|[\u3400-\u9FFF]+"#)
    private static let englishCue: Set<String> = ["hi", "hello", "hey", "please", "thanks", "thank", "yes", "no", "sorry", "can", "could", "did", "have", "how", "when", "what", "check"]

    static func requiresTranslation(_ text: String, to target: Language) -> Bool {
        let prose = protectedText.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        var latin = false, korean = false, chinese = false
        for scalar in prose.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0x00C0...0x024F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                latin = true
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF:
                korean = true
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                chinese = true
            default: return true // Do not mistake Japanese, Cyrillic, etc. for English.
            }
        }
        guard latin || korean || chinese else { return false }
        switch target {
        case .english: return korean || chinese
        case .korean: return chinese || !korean || (latin && hasEnglishPhrase(prose))
        case .chinese: return korean || !chinese || (latin && hasEnglishPhrase(prose))
        }
    }

    private static func hasEnglishPhrase(_ text: String) -> Bool {
        let raw = text as NSString
        var run = 0
        for match in words.matches(in: text, range: NSRange(location: 0, length: raw.length)) {
            let word = raw.substring(with: match.range)
            if englishCue.contains(word.lowercased()) { return true }
            // Preserve short borrowed names and identifiers inside Korean/Chinese sentences.
            let english = word.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
                && (word.first?.isUppercase != true || word == "I")
            run = english ? run + 1 : 0
            if run >= 3 { return true }
        }
        return false
    }
}
