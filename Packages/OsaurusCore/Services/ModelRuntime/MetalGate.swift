//
//  MetalGate.swift
//  osaurus
//
//  Mutual-exclusion gate preventing concurrent Metal command submissions
//  from MLX (generation) and CoreML (embedding). Overlapping submissions
//  cause EXC_BAD_ACCESS / SIGSEGV on Apple Silicon.
//
//  Today only the embedding side (`MetalSafeEmbedder`) calls into this gate.
//  MLX generation is fully delegated to vmlx-swift-lm's `BatchEngine`, whose
//  actor loop serializes Metal access from inside the library — we no longer
//  call `enterGeneration` from the request path. The generation API surface
//  is preserved here so embedding callers continue to interlock against any
//  future caller that does want exclusive MLX access (and so the existing
//  test suite keeps exercising the tri-state coordination logic).
//

import Foundation

public actor MetalGate {
    public static let shared = MetalGate()

    private var activeEmbeddings = 0
    /// Count of active MLX generations. `BatchEngine` does not feed this
    /// counter; it stays 0 in production but the API is kept so embedding
    /// callers can still rely on `enterEmbedding` waiting for any caller
    /// that explicitly opts back into the generation gate.
    private var activeGenerations = 0
    private var embeddingIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Embedding (CoreML)

    public func enterEmbedding() async {
        while activeGenerations > 0 {
            await withCheckedContinuation { cont in
                if activeGenerations > 0 {
                    generationIdleWaiters.append(cont)
                } else {
                    cont.resume()
                }
            }
        }
        activeEmbeddings += 1
    }

    public func exitEmbedding() {
        activeEmbeddings = max(0, activeEmbeddings - 1)
        if activeEmbeddings == 0 {
            let waiters = embeddingIdleWaiters
            embeddingIdleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    // MARK: - Generation (MLX) — kept for backward compatibility

    /// Strict MLX-vs-MLX serialization. Production gen does not call this
    /// (BatchEngine handles its own serialization) but it remains available
    /// for any future caller that needs exclusive Metal access against the
    /// embedding service.
    public func enterGeneration() async {
        while activeGenerations > 0 {
            await withCheckedContinuation { cont in
                if activeGenerations > 0 {
                    generationIdleWaiters.append(cont)
                } else {
                    cont.resume()
                }
            }
        }

        activeGenerations += 1
        while activeEmbeddings > 0 {
            await withCheckedContinuation { cont in
                if activeEmbeddings == 0 {
                    cont.resume()
                } else {
                    embeddingIdleWaiters.append(cont)
                }
            }
        }
    }

    public func exitGeneration() {
        activeGenerations = max(0, activeGenerations - 1)
        if activeGenerations == 0 {
            let waiters = generationIdleWaiters
            generationIdleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
