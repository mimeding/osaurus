//
//  MLXRuntimeTuning.swift
//  osaurus
//
//  Centralizes MLX runtime diagnostics that osaurus owns. Cache sizing and
//  context geometry stay delegated to vmlx-swift-lm.
//

import Darwin
import Foundation

enum MLXRuntimeTuning {

    private static let mebibyte = 1024 * 1024

    struct WiredMemoryAdvisory: Sendable, Equatable {
        let currentLimitMB: Int
        let recommendedMinimumMB: Int
    }

    static func currentWiredLimitMB() -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            sysctlbyname("iogpu.wired_limit_mb", pointer, &size, nil, 0)
        }
        guard result == 0, value > 0 else { return nil }
        return Int(value)
    }

    static func wiredMemoryAdvisory(
        modelBytes: Int64,
        currentLimitMB: Int?
    ) -> WiredMemoryAdvisory? {
        guard modelBytes > 0 else { return nil }
        let recommendedMinimumMB = Int((modelBytes + Int64(mebibyte - 1)) / Int64(mebibyte))
        guard recommendedMinimumMB >= 4096 else { return nil }
        guard let currentLimitMB, currentLimitMB > 0, currentLimitMB < recommendedMinimumMB else {
            return nil
        }
        return WiredMemoryAdvisory(
            currentLimitMB: currentLimitMB,
            recommendedMinimumMB: recommendedMinimumMB
        )
    }
}
