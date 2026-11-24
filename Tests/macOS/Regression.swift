import AppKit
import SwiftUI
import Translation

final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var authenticated = true
    static var accountStatus = 200
    static var sentTexts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let path = request.url!.path
        var code = 200
        var object: [String: Any] = ["items": []]
        if path.hasSuffix("/accounts") {
            code = Self.accountStatus
            object = ["items": [["id": "fixture", "authenticated": Self.authenticated]]]
        } else if path.hasSuffix("/sends") {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
            }
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            Self.sentTexts.append(payload?["text"] as? String ?? "MISSING")
            object = ["id": "fixture-send", "destination": "fixture-room", "state": "accepted"]
        }
        if code != 200 { object = ["error": ["code": code == 401 ? "needs_login" : "temporary_failure"]] }
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Regression {
    @MainActor static func check(_ passed: @autoclosure () -> Bool, _ name: String) {
        guard passed() else { print("FAIL: " + name); exit(1) }
        print("PASS: " + name)
    }
    @MainActor static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    @MainActor static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    @MainActor static func main() async throws {
        let suite = "wechat.regression.synthetic.20261124"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let backend = Backend(endpoint: "https://fixture.invalid/v1", session: URLSession(configuration: configuration))
        let model = ChatModel(preferences: preferences, preferredLanguages: ["ko"], backend: backend)
        model.account = Account(id: "fixture", authenticated: true)
        model.connected = true
        model.select("fixture-room")
        model.updateDraft("Please send the invoice.", edit: nil, in: "fixture-room")
        check(!model.shouldTranslateOnEnter, "English to English bypasses preview")
        await model.submitComposer()
        check(FixtureProtocol.sentTexts == ["Please send the invoice."] && model.draft.isEmpty, "one Enter sends same-language text")
        model.updateDraft("청구서를 보내주세요.", edit: nil, in: "fixture-room")
        check(model.shouldTranslateOnEnter, "Korean to English requires preview")
        await model.submitComposer()
        check(FixtureProtocol.sentTexts.count == 1 && model.config != nil, "submit does not send untranslated Korean")
        // Complete the pending translation through the same system session used by the UI.
        let translation = TranslationSession(installedSource: Locale.Language(identifier: "ko"), target: Locale.Language(identifier: "en"))
        await model.runTranslation(translation, generation: model.translationGeneration)
        check(model.preview != nil, "Apple preview completes")
        model.updatePreview("Please send the invoice, revised.", edit: nil, in: "fixture-room")
        await model.submitComposer()
        check(FixtureProtocol.sentTexts.last == "Please send the invoice, revised.", "edited preview is sent")
        model.updateDraft("https://soltech.co.kr/prod/sfc400hp/", edit: nil, in: "fixture-room")
        await model.submitComposer()
        check(FixtureProtocol.sentTexts.last == "https://soltech.co.kr/prod/sfc400hp/", "URL remains unchanged")
        model.updateDraft("보존할 초안", edit: nil, in: "fixture-room")
        model.ready = true
        FixtureProtocol.authenticated = false
        var poll = Task { await model.poll() }
        try await Task.sleep(for: .milliseconds(250)); poll.cancel(); await poll.value
        check(!model.connected && model.draft == "보존할 초안", "expired session returns to login and keeps draft")
        FixtureProtocol.authenticated = true
        poll = Task { await model.poll() }
        try await Task.sleep(for: .milliseconds(250)); poll.cancel(); await poll.value
        check(model.connected, "restored session reconnects")
        FixtureProtocol.accountStatus = 503
        poll = Task { await model.poll() }
        try await Task.sleep(for: .milliseconds(250)); poll.cancel(); await poll.value
        check(model.connected, "temporary server failure does not expire login")
        FixtureProtocol.accountStatus = 401
        poll = Task { await model.poll() }
        try await Task.sleep(for: .milliseconds(250)); poll.cancel(); await poll.value
        check(!model.connected && model.draft == "보존할 초안", "HTTP401 exposes login without discarding draft")
        FixtureProtocol.accountStatus = 200
        model.connected = true
        model.automaticTranslationEnabled = false
        model.rooms = [Room(id: "fixture-room", displayName: "Synthetic review", unreadCount: 0)]
        func message(_ id: Int) -> Message {
            let object: [String: Any] = ["id": String(id), "type": 1, "threadId": "fixture-room", "direction": "incoming",
                "body": "Synthetic message \(id): " + String(repeating: "scroll regression fixture ", count: 12)]
            return try! JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object))
        }
        model.messages = (0..<50).map(message)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: ChatView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<5 { pump() }
        guard let scroll = scrollViews(host).first(where: { ($0.documentView?.frame.height ?? 0) > 1500 }) else {
            print("FAIL: message scroll view not found"); exit(1)
        }
        func distance() -> CGFloat { (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY }
        check(distance() < 30, "chat initially shows latest message")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 250)); scroll.reflectScrolledClipView(scroll.contentView); pump()
        model.messages.append(message(50)); pump(); pump()
        check(distance() > 200, "new message preserves history reading position")
        model.translations["49"] = String(repeating: "Translation expansion fixture. ", count: 70); pump(); pump()
        check(distance() > 200, "translation expansion does not pull history to bottom")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView); pump()
        model.translations["50"] = String(repeating: "Latest translation expansion fixture. ", count: 90)
        for _ in 0..<4 { pump() }
        check(distance() < 30, "bottom follows expanded latest translation")
        window.orderOut(nil)
        print("All macOS regression checks passed. Only synthetic data was used.")
    }
}
