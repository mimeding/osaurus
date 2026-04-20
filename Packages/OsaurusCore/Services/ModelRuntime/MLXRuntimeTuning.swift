//
//  MLXRuntimeTuning.swift
//  osaurus
//
//  Centralizes conservative MLX runtime defaults so higher-memory Apple
//  Silicon machines can stretch context and cache budgets without changing
//  lower-RAM behavior.
//

import Darwin
import Foundation

enum MLXRuntimeTuning {

    private static let gibibyte = 1024 * 1024 * 1024
    private static let mebibyte = 1024 * 1024

    struct CacheProfile: Sendable, Equatable {
        let maxKV: Int
        let maxCacheBlocks: Int
        let diskCacheMaxGB: Float
    }

    struct WiredMemoryAdvisory: Sendable, Equatable {
        let currentLimitMB: Int
        let recommendedMinimumMB: Int
    }

    static func cacheProfile(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> CacheProfile {
        let ramGB = physicalMemory / UInt64(gibibyte)
        switch ramGB {
        case 0 ..< 24:
            return CacheProfile(maxKV: 8192, maxCacheBlocks: 500, diskCacheMaxGB: 4.0)
        case 24 ..< 48:
            return CacheProfile(maxKV: 16_384, maxCacheBlocks: 1000, diskCacheMaxGB: 6.0)
        case 48 ..< 96:
            return CacheProfile(maxKV: 32_768, maxCacheBlocks: 2000, diskCacheMaxGB: 8.0)
        case 96 ..< 128:
            return CacheProfile(maxKV: 65_536, maxCacheBlocks: 3000, diskCacheMaxGB: 12.0)
        default:
            return CacheProfile(maxKV: 131_072, maxCacheBlocks: 4000, diskCacheMaxGB: 16.0)
        }
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
