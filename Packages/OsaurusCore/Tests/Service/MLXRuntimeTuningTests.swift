import Testing

@testable import OsaurusCore

@Suite("MLX runtime tuning")
struct MLXRuntimeTuningTests {

    private static let mebibyte = Int64(1024 * 1024)

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
