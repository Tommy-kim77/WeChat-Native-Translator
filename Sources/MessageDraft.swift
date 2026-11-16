import Foundation

struct GroupMember: Decodable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    let roomDisplayName: String?
    let mentionName: String?

    var name: String { displayName ?? roomDisplayName ?? mentionName ?? id }
    var mentionText: String {
        let raw = mentionName ?? roomDisplayName ?? name
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{2005}"))
        let label = raw.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return "@" + (label.isEmpty || label.utf8.count > 1024 ? id : label) + "\u{2005}"
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [name, roomDisplayName ?? "", mentionName ?? "", id].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct TextSendRequest: Encodable, Equatable {
    struct Quote: Encodable, Equatable { let messageId: String; let serverId: String }

    struct Mentions: Encodable, Equatable {
        struct Position: Encodable, Equatable { let start: Int; let end: Int; let index: Int }
        let userIds: [String]
        let positions: [Position]
    }

    let threadId: String
    let text: String
    let mentions: Mentions?
    let quote: Quote?
}

struct DraftEdit {
    let range: NSRange
    let replacement: String
}

struct MentionQuery: Equatable {
    let range: NSRange
    let prefix: String

    init?(text: String, selection: NSRange) {
        guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let prefixText = String(text[..<caret])
        guard let match = prefixText.range(of: #"(?<![A-Za-z0-9_.+\-])@[^@\s\u2005]{0,64}$"#, options: .regularExpression) else { return nil }
        range = NSRange(match, in: prefixText)
        prefix = String(prefixText[match].dropFirst())
    }
}

struct MessageDraft: Equatable {
    private struct Mention: Equatable {
        let user: String
        var range: NSRange
    }

    private(set) var text: String
    private var mentions: [Mention] = []
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    init(_ text: String = "") { self.text = text }

    mutating func update(_ text: String, edit: DraftEdit?) {
        guard text != self.text else { return }
        guard let edit, let range = Range(edit.range, in: self.text),
              self.text.replacingCharacters(in: range, with: edit.replacement) == text else {
            // An edit without a verified range must not leave a stale recipient.
            self = MessageDraft(text)
            return
        }
        _ = replace(edit.range, with: edit.replacement)
    }

    mutating func insert(_ member: GroupMember, at range: NSRange) -> NSRange? {
        let label = member.mentionText
        guard let inserted = replace(range, with: label) else { return nil }
        mentions.append(Mention(user: member.id, range: inserted))
        mentions.sort { $0.range.location < $1.range.location }
        return NSRange(location: NSMaxRange(inserted), length: 0)
    }

    private mutating func replace(_ range: NSRange, with value: String) -> NSRange? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        let length = value.utf16.count
        let delta = length - range.length
        mentions = mentions.compactMap { mention in
            if NSMaxRange(mention.range) <= range.location { return mention }
            if mention.range.location < NSMaxRange(range) { return nil }
            return Mention(user: mention.user, range: NSRange(location: mention.range.location + delta, length: mention.range.length))
        }
        text.replaceSubrange(swiftRange, with: value)
        return NSRange(location: range.location, length: length)
    }

    private var translationExclusions: [(range: NSRange, user: String?)] {
        var exclusions = mentions.map { (range: $0.range, user: Optional($0.user)) }
        let matches = Self.linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let scheme = match.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !mentions.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
            exclusions.append((range: match.range, user: nil))
        }
        return exclusions.sorted { $0.range.location < $1.range.location }
    }

    private func textExcluding(_ ranges: [NSRange]) -> String {
        let body = NSMutableString(string: text)
        for range in ranges.reversed() { body.replaceCharacters(in: range, with: " ") }
        return body as String
    }

    var prose: String {
        textExcluding(translationExclusions.map(\.range)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isWebLinkOnly: Bool {
        let exclusions = translationExclusions
        return exclusions.contains { $0.user == nil }
            && !textExcluding(exclusions.map(\.range)).contains(where: \.isLetter)
    }

    func translated(using translate: (String) async throws -> String) async throws -> Self {
        let exclusions = translationExclusions
        if exclusions.isEmpty { return Self(try await translate(text)) }
        let original = text as NSString
        var result = Self()
        var start = 0
        for exclusion in exclusions {
            let segment = original.substring(with: NSRange(location: start, length: exclusion.range.location - start))
            result.text += try await Self.translateSegment(segment, using: translate)
            let position = result.text.utf16.count
            result.text += original.substring(with: exclusion.range)
            if let user = exclusion.user {
                result.mentions.append(Mention(user: user, range: NSRange(location: position, length: exclusion.range.length)))
            }
            start = NSMaxRange(exclusion.range)
        }
        result.text += try await Self.translateSegment(original.substring(from: start), using: translate)
        return result
    }

    private static func translateSegment(_ text: String, using translate: (String) async throws -> String) async throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.contains(where: \.isLetter), let range = text.range(of: body) else { return text }
        let translated = try await translate(body).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text[..<range.lowerBound]) + translated + String(text[range.upperBound...])
    }

    func request(for room: String, quote: TextSendRequest.Quote? = nil) -> TextSendRequest? {
        var trim = CharacterSet.whitespacesAndNewlines
        if !mentions.isEmpty { trim.remove(charactersIn: "\u{2005}") }
        guard let first = text.rangeOfCharacter(from: trim.inverted),
              let last = text.rangeOfCharacter(from: trim.inverted, options: .backwards) else { return nil }
        let bounds = first.lowerBound..<last.upperBound
        let offset = NSRange(bounds, in: text).location
        var users: [String] = []
        var positions: [TextSendRequest.Mentions.Position] = []
        for mention in mentions {
            if !users.contains(mention.user) { users.append(mention.user) }
            guard let index = users.firstIndex(of: mention.user) else { continue }
            positions.append(.init(start: mention.range.location - offset, end: NSMaxRange(mention.range) - offset, index: index))
        }
        return TextSendRequest(threadId: room, text: String(text[bounds]),
                               mentions: users.isEmpty ? nil : .init(userIds: users, positions: positions), quote: quote)
    }
}
