//
//  ModelServiceRouterTests.swift
//  osaurusTests
//
//  Verifies that `ModelServiceRouter.resolve` distinguishes between three
//  routing outcomes:
//    1. .service       — at least one service handles the model and is
//                        currently available.
//    2. .unavailable   — at least one service claims to handle the model
//                        (via `handles(requestedModel:)`) but every such
//                        service reports `!isAvailable()`. API layers map
//                        this to HTTP 503 so clients retry instead of
//                        reinstalling the model.
//    3. .none          — no service claims to handle the model at all.
//                        API layers map this to HTTP 404.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class StubModelService: ModelService, @unchecked Sendable {
    let id: String
    private let availability: Bool
    private let handler: @Sendable (String?) -> Bool

    init(
        id: String,
        isAvailable: Bool = true,
        handles: @escaping @Sendable (String?) -> Bool
    ) {
        self.id = id
        self.availability = isAvailable
        self.handler = handles
    }

    func isAvailable() -> Bool { availability }
    func handles(requestedModel: String?) -> Bool { handler(requestedModel) }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        return ""
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { $0.finish() }
    }
}

private func isService(_ route: ModelRoute) -> (id: String, effective: String)? {
    if case .service(let svc, let effective) = route {
        return (svc.id, effective)
    }
    return nil
}

private func isUnavailable(_ route: ModelRoute) -> String? {
    if case .unavailable(let requested) = route { return requested }
    return nil
}

private func isNone(_ route: ModelRoute) -> Bool {
    if case .none = route { return true }
    return false
}

struct ModelServiceRouterTests {

    @Test func resolveReturnsServiceWhenAvailable() {
        let svc = StubModelService(id: "local", isAvailable: true) { model in
            model == "qwen-3b"
        }
        let route = ModelServiceRouter.resolve(
            requestedModel: "qwen-3b",
            services: [svc]
        )
        let picked = isService(route)
        #expect(picked != nil)
        #expect(picked?.effective == "qwen-3b")
    }

    @Test func resolveReturnsNoneWhenNoServiceClaimsModel() {
        let svc = StubModelService(id: "local", isAvailable: true) { _ in false }
        let route = ModelServiceRouter.resolve(
            requestedModel: "unknown-model",
            services: [svc]
        )
        #expect(isNone(route))
    }

    @Test func resolveReturnsUnavailableWhenHandlerExistsButOffline() {
        // A service that claims to handle the model but reports unavailable
        // (e.g. Foundation Models on a Mac that doesn't support them, or
        // a remote provider that lost its connection between resolves).
        let svc = StubModelService(id: "foundation", isAvailable: false) { model in
            model == "foundation" || model == nil || model == "" || model == "default"
        }
        let route = ModelServiceRouter.resolve(
            requestedModel: "foundation",
            services: [svc]
        )
        #expect(isUnavailable(route) == "foundation")
    }

    @Test func resolvePrefersAvailableServiceOverUnavailableOne() {
        let offlineSvc = StubModelService(id: "offline", isAvailable: false) { $0 == "qwen" }
        let onlineSvc = StubModelService(id: "online", isAvailable: true) { $0 == "qwen" }
        let route = ModelServiceRouter.resolve(
            requestedModel: "qwen",
            services: [offlineSvc, onlineSvc]
        )
        #expect(isService(route)?.id == "online")
    }

    @Test func resolveUnavailableOnRemoteOnly() {
        let remote = StubModelService(id: "openai", isAvailable: false) { model in
            model?.hasPrefix("openai/") == true
        }
        let route = ModelServiceRouter.resolve(
            requestedModel: "openai/gpt-4",
            services: [],
            remoteServices: [remote]
        )
        #expect(isUnavailable(route) == "openai/gpt-4")
    }

    @Test func resolveDefaultModelRoutesToHandlingService() {
        let svc = StubModelService(id: "foundation", isAvailable: true) { model in
            model == nil || model == "" || model == "default"
        }
        let route = ModelServiceRouter.resolve(
            requestedModel: nil,
            services: [svc]
        )
        #expect(isService(route)?.effective == "foundation")
    }

    @Test func resolveDefaultUnavailableReturnsUnavailable() {
        let svc = StubModelService(id: "foundation", isAvailable: false) { model in
            model == nil || model == "" || model == "default"
        }
        let route = ModelServiceRouter.resolve(
            requestedModel: "",
            services: [svc]
        )
        // Empty/default requests surface as "default" in the error so the
        // user-facing message is still readable.
        #expect(isUnavailable(route) == "default")
    }
}
