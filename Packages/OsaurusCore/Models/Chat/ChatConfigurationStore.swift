//
//  ChatConfigurationStore.swift
//  osaurus
//
//  Persistence for ChatConfiguration (Application Support bundle directory)
//  Now delegates to AppConfiguration for cached reads.
//

import Foundation

@MainActor
public enum ChatConfigurationStore {
    /// Optional directory override for tests
    public static var overrideDirectory: URL?

    /// Load chat configuration from cache (no file I/O)
    /// File I/O is handled by AppConfiguration singleton
    public static func load() -> ChatConfiguration {
        return AppConfiguration.shared.chatConfig
    }

    /// Save chat configuration to disk and update cache.
    /// Errors are swallowed — see `saveThrowing` for the UI-catchable variant.
    public static func save(_ configuration: ChatConfiguration) {
        AppConfiguration.shared.updateChatConfig(configuration)
    }

    /// Throwing variant of `save`. Used by `ConfigurationView.saveConfiguration`
    /// to surface write failures as a toast. See
    /// `05-CONFIGURABILITY-AUDIT.md` Issue 10.
    public static func saveThrowing(_ configuration: ChatConfiguration) throws {
        try AppConfiguration.shared.updateChatConfigThrowing(configuration)
    }
}
