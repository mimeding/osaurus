import Foundation

struct ImportExportExportOption: Sendable, Equatable, Identifiable {
    let formatExtension: String
    let displayName: String

    var id: String { formatExtension }
}

enum ImportExportExportOptions {
    static func options(for source: ImportExportExportSource) -> [ImportExportExportOption] {
        var options: [ImportExportExportOption] = []

        func append(_ ext: String) {
            let normalized = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard !normalized.isEmpty else { return }
            guard ImportExportCapabilityRegistry.shared.canExport(formatExtension: normalized) else { return }
            guard !options.contains(where: { $0.formatExtension == normalized }) else { return }
            options.append(
                ImportExportExportOption(
                    formatExtension: normalized,
                    displayName: displayName(for: normalized)
                )
            )
        }

        switch source {
        case .text:
            append("pdf")

        case .attachment(let attachment):
            if let ext = attachment.fileExtension {
                append(ext)
            }
            if attachment.documentContent != nil {
                append("pdf")
            }

        case .artifact(let artifact):
            guard !artifact.isDirectory else { break }
            let filenameExtension = (artifact.filename as NSString).pathExtension
            if !filenameExtension.isEmpty {
                append(filenameExtension)
            }
            let hostExtension = (artifact.hostPath as NSString).pathExtension
            if !hostExtension.isEmpty {
                append(hostExtension)
            }
            if artifact.isText || artifact.isPDF || artifact.content != nil {
                append("pdf")
            }
        }

        return options
    }

    static func defaultOption(for source: ImportExportExportSource) -> ImportExportExportOption? {
        options(for: source).first
    }

    static func suggestedFilename(for source: ImportExportExportSource, option: ImportExportExportOption) -> String {
        let rawName: String
        switch source {
        case .text(_, let suggestedFilename):
            rawName = suggestedFilename ?? "export.txt"
        case .attachment(let attachment):
            rawName = attachment.filename ?? "attachment.txt"
        case .artifact(let artifact):
            rawName = artifact.filename
        }

        let basename = safeBasename(rawName)
        let baseWithoutExtension = (basename as NSString).deletingPathExtension
        let base = baseWithoutExtension.isEmpty ? "export" : baseWithoutExtension
        return "\(base).\(option.formatExtension)"
    }

    private static func displayName(for ext: String) -> String {
        switch ext {
        case "csv": return "CSV"
        case "tsv": return "TSV"
        case "pdf": return "PDF"
        default: return ext.uppercased()
        }
    }

    private static func safeBasename(_ rawName: String) -> String {
        let normalized = rawName.replacingOccurrences(of: "\\", with: "/")
        let basename = (normalized as NSString).lastPathComponent
        let scalars = basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "export" : cleaned
    }
}
