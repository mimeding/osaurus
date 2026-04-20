import Foundation
import UniformTypeIdentifiers

struct ImportExportCapabilityRegistry: Sendable {
    static let shared = ImportExportCapabilityRegistry(
        registrations: BuiltinImportExportCapabilities.defaultRegistrations()
    )

    let registrations: [ImportExportCapabilityRegistration]

    init(registrations: [ImportExportCapabilityRegistration]) {
        self.registrations = registrations
    }

    func capabilities(for role: ImportExportCapabilityRole? = nil) -> [ImportExportCapabilityMetadata] {
        registrations.compactMap { registration in
            guard role.map({ registration.metadata.roles.contains($0) }) ?? true else {
                return nil
            }
            return registration.metadata
        }
    }

    func capabilityMetadata(for url: URL) -> ImportExportCapabilityMetadata? {
        probe(url: url)?.metadata
    }

    func canImport(url: URL) -> Bool {
        resolveImport(url: url) != nil
    }

    func resolveImport(url: URL) -> ImportExportCapabilityImportResolution? {
        let request = ImportExportProbeRequest(url: url)

        for registration in registrations {
            guard
                registration.metadata.roles.contains(.import),
                let probe = registration.probe,
                let importer = registration.importer,
                let result = probe.probe(request: request, metadata: registration.metadata)
            else {
                continue
            }

            return ImportExportCapabilityImportResolution(
                metadata: registration.metadata,
                matchedExtension: result.matchedExtension,
                importer: importer
            )
        }

        return nil
    }

    func supportedDocumentTypes() -> [UTType] {
        var seenIdentifiers = Set<String>()
        var resolved: [UTType] = []

        for metadata in capabilities(for: .import) {
            for identifier in metadata.utTypeIdentifiers {
                guard seenIdentifiers.insert(identifier).inserted else { continue }
                if let type = UTType(identifier) {
                    resolved.append(type)
                }
            }
        }

        return resolved
    }

    func iconSymbol(forExtension ext: String) -> String? {
        let normalized = ext.lowercased()
        guard !normalized.isEmpty else { return nil }

        for registration in registrations {
            let supported = registration.metadata.supportedExtensions.map { $0.lowercased() }
            guard supported.contains(normalized) else { continue }
            return registration.metadata.iconSymbolNamesByExtension[normalized]
                ?? registration.metadata.defaultIconSymbolName
        }

        return nil
    }

    private func probe(url: URL) -> ImportExportCapabilityProbeResolution? {
        let request = ImportExportProbeRequest(url: url)

        for registration in registrations {
            guard let probe = registration.probe else { continue }
            guard let result = probe.probe(request: request, metadata: registration.metadata) else { continue }

            return ImportExportCapabilityProbeResolution(
                metadata: registration.metadata,
                matchedExtension: result.matchedExtension
            )
        }

        return nil
    }
}
