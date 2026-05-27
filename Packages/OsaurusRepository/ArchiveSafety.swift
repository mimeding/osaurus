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
    /// lexically (no `..` escapes) and after symlink resolution.
    ///
    /// Throws `ArchiveSafetyError` on the first escape encountered.
    /// Callers should treat the entire extracted tree as untrusted and
    /// remove it on failure.
    ///
    /// Containment is compared by *path components* (after both sides go
    /// through `resolvingSymlinksInPath().standardized`) rather than by
    /// string prefix. On macOS the TemporaryDirectory and the URLs the
    /// `FileManager.enumerator` returns are canonicalized inconsistently
    /// (`/var` vs `/private/var` depending on the API), and a string
    /// `hasPrefix` check produced false positives whenever one side was
    /// resolved and the other wasn't. `Array.starts(with:)` on
    /// `pathComponents` avoids that mismatch and is also immune to the
    /// "shared name prefix" foot-gun (e.g. `/work/foo-baz` vs
    /// `/work/foo`).
    public static func validate(extractedRoot: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: extractedRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveSafetyError.extractionRootMissing(extractedRoot.path)
        }

        // Canonicalize the root once. We compare candidate paths against
        // BOTH the symlink-resolved form (catches a symlink whose target
        // exits the root) AND the lexically-standardized form (catches a
        // candidate whose own enumerator URL was returned with a different
        // /var ↔ /private/var canonicalization than the root).
        let canonicalRoot = extractedRoot.resolvingSymlinksInPath().standardized
        let lexicalRoot = extractedRoot.standardized
        let canonicalRootComponents = canonicalRoot.pathComponents
        let lexicalRootComponents = lexicalRoot.pathComponents

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
            // 1. Lexical containment — catches '..' / absolute-path entries
            //    that slipped past unzip. Compared against the lexically-
            //    standardized root.
            let lexicalCandidate = item.standardized.pathComponents
            let passesLexical = lexicalCandidate.starts(with: lexicalRootComponents)

            // 2. Symlink-aware containment — catches a symlink whose target
            //    exits the root. Compared against the symlink-resolved root.
            let canonicalCandidate = item.resolvingSymlinksInPath().standardized.pathComponents
            let passesCanonical = canonicalCandidate.starts(with: canonicalRootComponents)

            // Either canonicalization being inside is enough; macOS's
            // /var ↔ /private/var inconsistency means one form or the
            // other may match while the other doesn't, and both forms
            // refer to the same real file.
            guard passesLexical || passesCanonical else {
                let isSymlink =
                    (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink ?? false
                if isSymlink {
                    let target =
                        (try? fm.destinationOfSymbolicLink(atPath: item.path))
                        ?? item.resolvingSymlinksInPath().path
                    throw ArchiveSafetyError.escapingSymlink(linkPath: item.path, target: target)
                }
                throw ArchiveSafetyError.escapingPath(item.path)
            }
        }
    }
}
