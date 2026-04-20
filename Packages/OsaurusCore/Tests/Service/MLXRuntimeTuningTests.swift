import Testing

@testable import OsaurusCore

@Suite("MLX runtime tuning")
struct MLXRuntimeTuningTests {

    private static let gibibyte = UInt64(1024 * 1024 * 1024)
    private static let mebibyte = Int64(1024 * 1024)

    @Test("RAM tiers scale context and cache budgets for newer Apple Silicon")
    func cacheProfilesFollowMemoryTiers() {
        #expect(
            MLXRuntimeTuning.cacheProfile(physicalMemory: 16 * Self.gibibyte)
                == .init(maxKV: 8192, maxCacheBlocks: 500, diskCacheMaxGB: 4)
        )
        #expect(
            MLXRuntimeTuning.cacheProfile(physicalMemory: 32 * Self.gibibyte)
                == .init(maxKV: 16_384, maxCacheBlocks: 1000, diskCacheMaxGB: 6)
        )
        #expect(
            MLXRuntimeTuning.cacheProfile(physicalMemory: 64 * Self.gibibyte)
                == .init(maxKV: 32_768, maxCacheBlocks: 2000, diskCacheMaxGB: 8)
        )
        #expect(
            MLXRuntimeTuning.cacheProfile(physicalMemory: 96 * Self.gibibyte)
                == .init(maxKV: 65_536, maxCacheBlocks: 3000, diskCacheMaxGB: 12)
        )
        #expect(
            MLXRuntimeTuning.cacheProfile(physicalMemory: 128 * Self.gibibyte)
                == .init(maxKV: 131_072, maxCacheBlocks: 4000, diskCacheMaxGB: 16)
        )
    }

    @Test("Wired-memory advisory triggers only when the model materially exceeds the current limit")
    func wiredMemoryAdvisoryMatchesLargeModels() {
        let advisory = MLXRuntimeTuning.wiredMemoryAdvisory(
            modelBytes: 12_288 * Self.mebibyte,
            currentLimitMB: 8192
        )
        #expect(advisory == .init(currentLimitMB: 8192, recommendedMinimumMB: 12_288))

        #expect(
            MLXRuntimeTuning.wiredMemoryAdvisory(
                modelBytes: 2048 * Self.mebibyte,
                currentLimitMB: 1024
            ) == nil
        )
        #expect(
            MLXRuntimeTuning.wiredMemoryAdvisory(
                modelBytes: 12_288 * Self.mebibyte,
                currentLimitMB: 16_384
            ) == nil
        )
        #expect(
            MLXRuntimeTuning.wiredMemoryAdvisory(
                modelBytes: 12_288 * Self.mebibyte,
                currentLimitMB: nil
            ) == nil
        )
    }
}
