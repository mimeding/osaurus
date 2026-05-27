//
//  ArchiveSafety.swift
//  OsaurusRepository
//
//  Post-extraction validation that catches ZIP-slip and symlink-escape
//  attempts. After extracting an archive into a destination directory,
//  call `ArchiveSafety.validate(extractedRoot:)` and abort the install
//  if it throws. Validation is symlink-aware: every regular file, every
//  directory, and every symlink target is required to resolve to a path
//  inside the destination root.
//
//  Why post-extraction:
//    * Streaming-time validation would require a ZIP library; we currently
//      shell out to /usr/bin/unzip and the same logic is duplicated across
//      callers (PluginInstallManager, SkillManager, CLI ToolsInstall).
//    * The destination root is a freshly-created temp directory the caller
//      owns. Until validate() succeeds, the caller must not move or read
//      the extracted contents.
//    * Symlinks introduced by the archive (or by a sloppy build) are the
//      attack vector left over once the unzip tool itself starts rejecting
//      absolute / ".." entries. macOS Info-ZIP already rejects absolute
//      paths and many ".." escapes; symlinks pointing outside the tree are
//      what we still have to police.
//

import Foundation

public enum ArchiveSafetyError: Error, CustomStringConvertible {
    case escapingPath(String)
    case escapingSymlink(linkPath: String, target: String)
    case extractionRootMissing(String)

    public var description: String {
        switch self {
        case .escapingPath(let p):
            return "Archive entry resolves outside the extraction root: \(p)"
        case .escapingSymlink(let link, let target):
            return "Archive symlink \(link) points outside the extraction root: \(target)"
        case .extractionRootMissing(let p):
            return "Extraction root does not exist or is not a directory: \(p)"
        }
    }
}

public enum ArchiveSafety {

    /// Walk `extractedRoot` and verify every entry is contained — both
    /// lexically (after `.standardized`) and after symlink resolution.
    ///
    /// Throws `ArchiveSafetyError` on the first escape encountered.
    /// Callers should treat the entire extracted tree as untrusted and
    /// remove it on failure.
    public static func validate(extractedRoot: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: extractedRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveSafetyError.extractionRootMissing(extractedRoot.path)
        }

        // Compare against a symlink-resolved root so projects whose temp dir
        // happens to live under a system symlink (e.g. macOS /var ->
        // /private/var) don't fail spuriously.
        let resolvedRoot = extractedRoot.resolvingSymlinksInPath().standardized.path
        let rootWithSeparator =
            resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"

        guard
            let enumerator = fm.enumerator(
                at: extractedRoot,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
        else {
            return
        }

        for case let item as URL in enumerator {
            // 1. Lexical containment: each entry's standardized path must
            //    start with the resolved root prefix. This catches the
            //    happy-path case for plain files in a well-formed archive.
            let standardized = item.standardized.path
            guard standardized == resolvedRoot || standardized.hasPrefix(rootWithSeparator) else {
                throw ArchiveSafetyError.escapingPath(item.path)
            }

            // 2. Symlink-aware containment: if `item` itself is a symlink
            //    OR any component along its path is, the symlink's target
            //    must still live inside the root. We resolve the entry
            //    once and compare.
            let resolved = item.resolvingSymlinksInPath().standardized.path
            guard resolved == resolvedRoot || resolved.hasPrefix(rootWithSeparator) else {
                let isSymlink =
                    (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink ?? false
                if isSymlink {
                    let target =
                        (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? resolved
                    throw ArchiveSafetyError.escapingSymlink(linkPath: item.path, target: target)
                }
                throw ArchiveSafetyError.escapingPath(item.path)
            }
        }
    }
}
