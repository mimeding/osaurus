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

    func canExport(formatExtension: String) -> Bool {
        resolveExport(formatExtension: formatExtension) != nil
    }

    func canExport(url: URL) -> Bool {
        resolveExport(url: url) != nil
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

    func resolveExport(url: URL) -> ImportExportCapabilityExportResolution? {
        resolveExport(formatExtension: url.pathExtension)
    }

    func resolveExport(formatExtension: String) -> ImportExportCapabilityExportResolution? {
        let normalized = formatExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        let probeURL = URL(fileURLWithPath: "export.\(normalized)")
        let request = ImportExportProbeRequest(url: probeURL)

        for registration in registrations {
            guard
                registration.metadata.roles.contains(.export),
                !registration.metadata.isScaffoldOnly,
                let probe = registration.probe,
                let exporter = registration.exporter,
                let result = probe.probe(request: request, metadata: registration.metadata)
            else {
                continue
            }

            return ImportExportCapabilityExportResolution(
                metadata: registration.metadata,
                matchedExtension: result.matchedExtension,
                exporter: exporter
            )
        }

        return nil
    }

    @discardableResult
    func export(
        source: ImportExportExportSource,
        to destinationURL: URL,
        formatExtension explicitFormatExtension: String? = nil
    ) throws -> ImportExportExportResult {
        let formatExtension = explicitFormatExtension ?? destinationURL.pathExtension
        guard let resolution = resolveExport(formatExtension: formatExtension) else {
            throw ImportExportExportError.unsupportedFormat(formatExtension)
        }

        let request = ImportExportExportRequest(
            source: source,
            destinationURL: destinationURL,
            formatExtension: resolution.matchedExtension
        )
        return try resolution.exporter.exportFile(request: request, metadata: resolution.metadata)
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
