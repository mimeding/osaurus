# Community Plugin Catalog

Osaurus ships a trusted community catalog for the in-app plugin browser. The
catalog is lightweight metadata layered on top of the signed plugin specs in the
trusted registry. It does not replace install verification.

## Runtime Flow

1. The app loads `Resources/PluginCatalog/community-plugin-catalog.json`.
2. `PluginRepositoryService` refreshes the trusted plugin registry and decodes
   each `PluginSpec`.
3. Catalog rows are merged by `plugin_id` to add category, tags, featured rank,
   trust notes, and install notes.
4. The browser builds an install preview from the spec before offering install.
   A preview only enables install when a compatible macOS arm64 artifact exists,
   the artifact is signed, the registry exposes the signing public key, and the
   declared archive size fits the installer limit. Catalog entries with missing
   or withheld trust stay visible but disabled with a blocking reason.
5. The final install still runs through `PluginInstallManager`, including
   download, checksum validation, minisign verification, extraction, receipt
   writing, and plugin reload.

If the registry is unavailable, the bundled catalog can still show known plugin
rows. Those rows become fully previewable after a registry refresh supplies the
matching signed spec. Until then, the Install action is disabled and the preview
explains that registry metadata must be refreshed before install.

## Trust and Install Health

Install previews expose three catalog trust states:

- `trustedCatalog`: the plugin is listed in the bundled catalog with
  `trust.trusted: true`.
- `registryOnly`: the plugin came from the signed registry but is not listed in
  the bundled catalog. It can still install if the signed release checks pass,
  but the preview shows a warning.
- `reviewRequired`: the catalog entry is missing an explicit trusted review or
  has `trust.trusted: false`. The browser disables install until maintainers
  update the catalog trust metadata.

Unavailable previews carry typed failure reasons so the UI can show an
actionable disabled state:

- `catalogReviewRequired`: catalog trust review is incomplete.
- `missingRegistryRelease`: the catalog row has no loaded registry spec, or the
  registry spec has no release yet.
- `incompatiblePlatform`: no macOS arm64 artifact is published.
- `missingArtifactSignature`: the selected release is missing minisign metadata.
- `missingRegistrySigningKey`: the registry spec is missing the minisign public
  key.
- `archiveTooLarge`: the declared archive size exceeds the installer limit.

## Catalog Schema

```json
{
  "schema_version": 1,
  "source_name": "Osaurus community plugin catalog",
  "source_url": "https://github.com/osaurus-ai/osaurus-tools",
  "trusted_registry_url": "https://github.com/osaurus-ai/osaurus-tools.git",
  "generated_at": "2026-06-18",
  "plugins": [
    {
      "plugin_id": "osaurus.browser",
      "name": "Browser",
      "summary": "Browse pages, inspect DOM state, and automate web workflows.",
      "category": "Web",
      "tags": ["browser", "automation", "web"],
      "featured": true,
      "sort_rank": 10,
      "install_note": "Optional note shown in the install preview.",
      "trust": {
        "trusted": true,
        "source": "osaurus-tools",
        "reviewed_by": "Maintainers",
        "notes": "Listed from the trusted plugin registry."
      }
    }
  ]
}
```

Required field:

- `plugin_id`: must match the registry `PluginSpec.plugin_id`.

Optional fields:

- `name`, `summary`: browser fallback text when the registry spec is not loaded.
- `category`: category chip key. Spaces and underscores normalize to hyphens.
- `tags`: search keywords and preview chips.
- `featured`, `sort_rank`: browse ordering hints.
- `install_note`: extra user-facing install context.
- `trust`: display and audit metadata for the catalog source.

## Safety Rules

- Do not add arbitrary install URLs to the catalog. Artifact URLs live only in
  signed registry specs.
- Do not mark a plugin installable from catalog metadata alone.
- Do not bypass `PluginInstallManager` verification for catalog installs.
- Do not set `trust.trusted: true` unless the entry was reviewed against the
  intended registry plugin ID and signed release metadata.
- Keep catalog metadata descriptive. Capability truth comes from the registry
  spec and the loaded plugin manifest.
