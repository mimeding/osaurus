# Import and Export Capabilities

This document describes the capability registry introduced after PR #893. The strategic goal is to make file handling declarative: chat remains the product surface, tools remain the capability surface, and import/export behavior is described by registry metadata instead of scattered hard-coded extension checks.

## Current Contract

`ImportExportCapabilityRegistry` is the source of truth for document and artifact capability metadata. It records:

- supported file extensions and UTType identifiers;
- whether a capability can probe, import, export, or validate;
- the canonical target, such as `Attachment.document` or `SharedArtifact`;
- runtime requirements, such as Foundation, AppKit, or PDFKit;
- prompt-safety and active-content risk metadata;
- icon metadata used by chat attachments.

`DocumentParser` now resolves import behavior through the registry. `Attachment.fileIcon` also resolves through the registry so UI metadata follows the same source of truth as parser support.

## Supported Import Paths

| Capability | Extensions | Prompt behavior | Risk |
| --- | --- | --- | --- |
| Plain text and code attachments | `txt`, `md`, `log`, source-code extensions, shell/config files | Reads as plain text | Low |
| Delimited text attachments | `csv`, `tsv` | Reads as plain text | Low |
| Structured text attachments | `json`, `xml`, `yaml`, `yml`, `toml` | Reads as plain text | Low |
| PDF attachments | `pdf` | Extracts PDF text; renders pages as images when no text is available | Medium |
| Rich document attachments | `docx`, `doc`, `rtf`, `rtfd`, `html`, `htm` | Extracts text through platform document readers | Medium |

These paths preserve the current lightweight chat-ingest behavior. They do not yet preserve workbook semantics, Office document structure, PDF layout, or editable rich-document formatting.

## Scaffold-Only Export Path

The registry includes `builtin.generic-artifact-passthrough` for artifact export and validation metadata. That entry is intentionally scaffold-only in this slice. It documents the existing lightweight artifact path and gives future work a stable place to attach real export and validation implementations.

Scaffold-only means:

- the capability appears in registry metadata;
- risk, supported formats, and runtime intent are visible to developers;
- export and validation hooks are not treated as production implementations yet;
- callers must not assume semantic conversion, workbook generation, PDF validation, or Office export is complete.

## Development Direction

Future import/export work should add or replace registry capabilities instead of adding new extension switch statements in UI or parser code. A new capability should include metadata, a focused implementation, and tests for:

- extension and UTType resolution;
- prompt-safety behavior;
- maximum input size or output-boundary enforcement;
- scaffold-only behavior if the implementation is intentionally incomplete;
- UI icon metadata if the format appears in chat.

This keeps file handling extensible without recreating Work Mode or burying file behavior inside chat view logic.
