# Import and Export Capabilities

This document describes the capability registry introduced after PR #893. The strategic goal is to make file handling declarative: chat remains the product surface, tools remain the capability surface, and import/export behavior is described by registry metadata instead of scattered hard-coded extension checks.

## Maintainer Alignment

This design follows the maintainer-facing direction established by PR #893:

- file behavior is a capability, not a separate mode;
- chat is where users import, inspect, and receive files;
- support is explicit in registry metadata before UI code exposes it;
- scaffold-only entries are documented, but never presented as completed features;
- format support is intentionally narrow until Osaurus has the right source model for richer fidelity.

## Current Contract

`ImportExportCapabilityRegistry` is the source of truth for document and artifact capability metadata. It records:

- supported file extensions and UTType identifiers;
- whether a capability can probe, import, export, or validate;
- the canonical target, such as `Attachment.document` or `SharedArtifact`;
- runtime requirements, such as Foundation, AppKit, or PDFKit;
- prompt-safety and active-content risk metadata;
- icon metadata used by chat attachments.

`DocumentParser` now resolves import behavior through the registry. `Attachment.fileIcon` also resolves through the registry so UI metadata follows the same source of truth as parser support.

Export behavior also resolves through the registry. Callers pass an explicit `ImportExportExportSource` and destination URL to the registry; the registry selects only a real, non-scaffold exporter for the requested destination extension.

Chat artifact cards use the same registry contract for their Export action. The UI presents export only when a real exporter is available, so scaffold-only metadata cannot appear as a finished file conversion path.

## Supported Import Paths

| Capability | Extensions | Prompt behavior | Risk |
| --- | --- | --- | --- |
| Markdown attachments | `md`, `markdown` | Reads as plain text with Markdown source preserved | Low |
| Plain text and code attachments | `txt`, `log`, source-code extensions, shell/config files | Reads as plain text | Low |
| Delimited text attachments | `csv`, `tsv` | Reads as plain text | Low |
| Structured text attachments | `json`, `xml`, `yaml`, `yml`, `toml` | Reads as plain text | Low |
| PDF attachments | `pdf` | Extracts PDF text; renders pages as images when no text is available | Medium |
| Rich document attachments | `docx`, `doc`, `rtf`, `rtfd`, `html`, `htm` | Extracts text through platform document readers | Medium |

These paths preserve the current lightweight chat-ingest behavior. They do not yet preserve workbook semantics, Office document structure, PDF layout, or editable rich-document formatting.

## Supported Export Paths

| Capability | Extensions | Source behavior | Fidelity |
| --- | --- | --- | --- |
| Markdown attachments | `md`, `markdown` | Writes text, document attachments, or text artifacts | Preserves Markdown source text; normalizes line endings |
| Delimited text attachments | `csv`, `tsv` | Writes text, document attachments, or text artifacts | Preserves caller-provided delimited content; normalizes line endings |
| PDF attachments | `pdf` | Writes text/document sources to a paginated PDF; copies existing PDF artifacts | Readable text PDF, not source-layout preservation |

Markdown export is deliberately source-preserving. It does not render Markdown into HTML or PDF, and it does not attempt rich document conversion. This keeps `.md` support aligned with chat-first file handling: the source document remains inspectable and prompt-safe.

CSV and TSV export are intentionally lightweight. The exporter does not infer a workbook model, type cells, or rewrite delimiters. It preserves the caller-provided text content and normalizes line endings so the saved file is predictable.

PDF export is intentionally conservative. Text and document sources become a simple paginated PDF using AppKit/CoreText. Existing PDF artifacts are copied as PDFs. This makes PDF export useful immediately without claiming rich layout conversion.

## Scaffold-Only Export Path

The registry includes `builtin.generic-artifact-passthrough` for artifact export and validation metadata. That entry is intentionally scaffold-only in this slice. It documents the existing lightweight artifact path and gives future work a stable place to attach real export and validation implementations.

Scaffold-only means:

- the capability appears in registry metadata;
- risk, supported formats, and runtime intent are visible to developers;
- export and validation hooks are not treated as production implementations for generic passthrough formats yet;
- callers must not assume semantic conversion, workbook generation, PDF validation, or Office export is complete.

Real exporters, such as Markdown, CSV/TSV, and PDF, are registered separately and are not scaffold-only.

## Development Direction

Future import/export work should add or replace registry capabilities instead of adding new extension switch statements in UI or parser code. A new capability should include metadata, a focused implementation, and tests for:

- extension and UTType resolution;
- prompt-safety behavior;
- maximum input size or output-boundary enforcement;
- export destination validation;
- import/export round trips where the format supports it;
- scaffold-only behavior if the implementation is intentionally incomplete;
- UI icon metadata if the format appears in chat.

This keeps file handling extensible without recreating Work Mode or burying file behavior inside chat view logic.

## Next Targets

1. Add attachment-chip export affordances for imported documents.
2. Add format-choice UI when a source supports more than one real exporter.
3. Add richer CSV/table export only after Osaurus has a table model.
4. Improve generated PDF layout after the basic registry-backed PDF path is stable.
5. Add JSON export once the source model can distinguish raw text from structured records.
