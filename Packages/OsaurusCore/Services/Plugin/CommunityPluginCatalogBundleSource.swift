//
//  CommunityPluginCatalogBundleSource.swift
//  osaurus
//
//  Loads the bundled trusted community plugin catalog.
//

import Foundation
import OsaurusRepository

enum CommunityPluginCatalogBundleSource {
    enum LoadError: Error, LocalizedError {
        case missingResource

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "Bundled community plugin catalog is missing."
            }
        }
    }

    static func loadBundled() throws -> CommunityPluginCatalog {
        guard
            let url = Bundle.module.url(
                forResource: "community-plugin-catalog",
                withExtension: "json",
                subdirectory: "PluginCatalog"
            )
                ?? Bundle.module.url(
                    forResource: "community-plugin-catalog",
                    withExtension: "json"
                )
        else {
            throw LoadError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CommunityPluginCatalog.self, from: data)
    }
}
