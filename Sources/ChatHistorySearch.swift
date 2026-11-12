import SwiftUI

struct ChatHistorySearch: View {
    @ObservedObject var model: ChatModel
    let room: String
    @State private var input = ""
    @State private var results: [Message] = []
    @State private var nextCursor: String?
    @State private var failure: UIMessage?
    @State private var loading = false
    @State private var moreTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var language: Language { model.interfaceLanguage }
    private var query: String {
        var bytes = input.trimmingCharacters(in: .whitespacesAndNewlines).utf8.prefix(256)
        while String(bytes: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(language.label("대화 기록 검색"), text: $input).focused($focused)
            if let failure { Text(failure.text(in: language)).foregroundStyle(.secondary) }
            if !query.isEmpty, results.isEmpty, !loading, failure == nil, nextCursor == nil {
                Text(language.label("검색 결과가 없습니다.")).foregroundStyle(.secondary)
            }
            if !results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if message.outgoing || room.hasSuffix("@chatroom") && message.hasSender {
                                        Text(message.outgoing ? language.label("나") : model.groupSenderName(message.senderId, in: room))
                                    }
                                    if let timestamp = message.createdAt, let date = try? Date(timestamp, strategy: .iso8601) {
                                        Text(date, format: .dateTime.month().day().hour().minute())
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                Text(model.isRecalled(message) ? language.label("회수된 메시지")
                                     : message.body ?? language.label(message.attachmentLabelKey ?? "[첨부 또는 시스템 메시지]"))
                                    .textSelection(.enabled)
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight: 320)
            }
            if loading { ProgressView().controlSize(.small) }
            if let nextCursor, !loading {
                Button(language.label("검색 결과 더 보기")) {
                    moreTask = Task { await fetch(query, cursor: nextCursor) }
                }
            }
        }
        .padding(14).frame(width: 350)
        .onAppear { focused = true }
        .onDisappear { moreTask?.cancel() }
        .task(id: query) {
            moreTask?.cancel()
            results = []
            nextCursor = nil
            failure = nil
            loading = !query.isEmpty
            let requested = query
            guard !requested.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await fetch(requested, cursor: nil)
        }
    }

    private func fetch(_ requested: String, cursor: String?) async {
        guard !Task.isCancelled, requested == query else { return }
        loading = true
        failure = nil
        defer { if !Task.isCancelled, requested == query { loading = false } }
        do {
            let page = try await model.searchMessages(in: room, query: requested, cursor: cursor)
            guard requested == query else { return }
            let seen = Set(results.map(\.id))
            results.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, requested == query { failure = UIMessage(error: error, prefix: "대화 기록 검색 실패 · %@") }
        }
    }
}
