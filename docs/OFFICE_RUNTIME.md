# Office Runtime

Osaurus business-file workflows are designed to run in two layers:

1. **Native paths** — Create or inspect supported file formats directly in Osaurus.
2. **Enhanced paths** — Use a locally installed office runtime for validation, PDF export, and previews when that runtime is available.

LibreOffice and OpenOffice are optional. Osaurus does not bundle either application, does not download them automatically, and does not require users to install them for native document or presentation workflows.

---

## Runtime Detection

Enhanced flows should detect an installed office runtime on demand. Typical discovery locations include:

- The `soffice` command on `PATH`
- `/Applications/LibreOffice.app/Contents/MacOS/soffice`
- `/Applications/OpenOffice.app/Contents/MacOS/soffice`

Detection should be fast, local, and non-invasive. If neither runtime is found, Osaurus should continue with native functionality and report that enhanced preview/export is unavailable.

---

## Supported Enhanced Flows

When LibreOffice or OpenOffice is installed, Osaurus can use it for workflows that benefit from an independent office renderer:

| Flow              | Purpose                                                     |
| ----------------- | ----------------------------------------------------------- |
| Validation        | Open or convert a generated office file to catch corruption |
| PDF export        | Export DOCX, XLSX, or PPTX artifacts to PDF                 |
| Slide previews    | Render presentation slides for visual review                |

These enhanced flows are best-effort additions to native file support. They should not change the requirement that native generation and analysis paths behave predictably without office software.

---

## PPTX Capability Model

PPTX support is expressed as two capability paths:

| Capability                         | Meaning                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------- |
| **PPTX: Native**                   | Generate or inspect PPTX artifacts without external office software      |
| **PPTX: Enhanced with LibreOffice** | Use LibreOffice or OpenOffice for validation, PDF export, and previews   |
| **LibreOffice not found**          | Enhanced preview/export unavailable; native PPTX workflows remain usable |

User-facing capability text should be explicit about which path is active. Avoid wording that implies LibreOffice is bundled or required.

---

## Install Hint

Documentation may tell users how to install an office runtime when they want enhanced preview/export:

```bash
brew install --cask libreoffice
```

This is a documentation hint only. Osaurus should not force installation, prompt for automatic installation, or make enhanced flows a prerequisite for native business-file work.
