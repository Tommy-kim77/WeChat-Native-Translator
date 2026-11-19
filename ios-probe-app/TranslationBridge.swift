import Foundation
import SwiftUI
import Translation
import UIKit
import NaturalLanguage

// Runs translation on-device through Apple's Translation framework.
// Requires iOS 18+, device language resources and user approval for downloads.
@MainActor
@objc(WeChatTranslationBridge)
public final class WeChatTranslationBridge: NSObject, ObservableObject {
    private struct Request {
        let text: String
        let source: Locale.Language?
        let completion: (NSString?, NSString?) -> Void
    }

    @Published var configuration: TranslationSession.Configuration?
    @Published var sessionGeneration = 0
    private var pending: [Request] = []
    private var active: Request?
    private var targetLanguage = "ko"
    private var completedCount = 0
    private var failedCount = 0

    private func record(_ event: String) {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("wechat-translation-diagnostics.log")
        let line = "\(Date().timeIntervalSince1970) \(event) completed=\(completedCount) failed=\(failedCount) queued=\(pending.count)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else { try? Data(line.utf8).write(to: URL(fileURLWithPath: path)) }
    }

    @objc public func setTargetLanguage(_ code: NSString) {
        let normalized = code as String
        guard ["ko", "en", "zh-Hans"].contains(normalized) else { return }
        targetLanguage = normalized
    }

    private static func sourceLanguage(for text: String) -> Locale.Language? {
        // Language detection is done *per message*: one Apple session must not
        // be reused across English/Chinese mixed conversations.
        // Script detection precedes statistical guessing: short "你好" and
        // "今天是几号？" are frequently misclassified by the recognizer.
        let hasHangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        let hasHan = text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) ||
            (0x3400...0x4DBF).contains($0.value)
        }
        if hasHan && !hasHangul { return Locale.Language(identifier: "zh-Hans") }
        if hasHangul && !hasHan { return Locale.Language(identifier: "ko") }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let detected = recognizer.dominantLanguage {
            switch detected {
            case .simplifiedChinese, .traditionalChinese:
                return Locale.Language(identifier: "zh-Hans")
            case .english:
                return Locale.Language(identifier: "en")
            case .korean:
                return Locale.Language(identifier: "ko")
            default:
                break
            }
        }
        // Short Latin texts may have no reliable NLLanguageRecognizer result.
        if text.unicodeScalars.contains(where: {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }) { return Locale.Language(identifier: "en") }
        return nil
    }

    @objc public func translateText(_ text: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        let original = (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            completion(nil, "Empty input")
            return
        }
        pending.append(Request(text: original, source: Self.sourceLanguage(for: original), completion: completion))
        record("ENQUEUED")
        startNext()
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        let target = Locale.Language(identifier: targetLanguage)
        active = next
        sessionGeneration += 1
        record("SESSION_START")
        configuration = .init(source: next.source, target: target)
    }

    @objc public func makeWorkerViewController() -> UIViewController {
        UIHostingController(rootView: TranslationWorker(engine: self))
    }

    func run(_ session: TranslationSession) async {
        guard let request = active else { return }
        record("SESSION_RUN")
        do {
            let response = try await session.translate(request.text)
            completedCount += 1
            record("TRANSLATION_SUCCESS")
            request.completion(response.targetText as NSString, nil)
        } catch {
            failedCount += 1
            record("TRANSLATION_ERROR")
            request.completion(nil, String(describing: error) as NSString)
        }
        active = nil
        configuration = nil
        // SwiftUI must first render the empty configuration. A same-turn nil ->
        // new value update can be coalesced and permanently stall the queue.
        if !pending.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                startNext()
            }
        }
    }
}

private struct TranslationWorker: View {
    @ObservedObject var engine: WeChatTranslationBridge
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(engine.configuration) { session in
                await engine.run(session)
            }
            .id(engine.sessionGeneration)
    }
}
