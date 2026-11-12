import SwiftUI
import Translation

@MainActor
final class AppleTranslationRoute: ObservableObject {
    private struct Request {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    @Published private(set) var configuration: TranslationSession.Configuration?
    private var request: Request?
    var requestID: UUID? { request?.id }

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request?.continuation.resume(throwing: CancellationError())
                request = Request(id: id, text: text, continuation: continuation)
                let from = Locale.Language(identifier: source.rawValue)
                let to = Locale.Language(identifier: target.rawValue)
                if configuration?.source == from, configuration?.target == to { configuration?.invalidate() }
                else { configuration = .init(source: from, target: to) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, result: .failure(CancellationError())) }
        }
    }

    func run(_ session: TranslationSession, id: UUID?) async {
        guard let request, request.id == id else { return }
        do {
            let text = try await session.translate(request.text).targetText
            finish(request.id, result: .success(text))
        } catch { finish(request.id, result: .failure(error)) }
    }

    private func finish(_ id: UUID, result: Result<String, Error>) {
        guard let request, request.id == id else { return }
        self.request = nil
        request.continuation.resume(with: result)
    }
}

struct AppleTranslationRouteView: View {
    @ObservedObject var route: AppleTranslationRoute

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .translationTask(route.configuration) { [id = route.requestID] session in
                await route.run(session, id: id)
            }
    }
}
