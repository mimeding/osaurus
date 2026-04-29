---
name: document-data-analyst
description: Analyze PDFs, CSVs, spreadsheets, tables, and structured attachments with careful extraction, validation, summaries, and chart-ready outputs.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: documents
  keywords: "PDF, CSV, XLSX, spreadsheet, workbook, table, document analysis, extraction, chart, attachment"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Document Data Analyst

Use this skill when working with attached documents, spreadsheets, reports, or tabular data.

## Extraction

- Identify file type and the most reliable parser before transforming content.
- Preserve sheet names, table headings, page numbers, and units where available.
- Validate row counts, column names, totals, and obvious type conversions.

## Analysis

- Separate raw extraction from interpretation.
- Use tables for comparisons and concise bullets for findings.
- Flag missing values, inconsistent units, or possible OCR/parser errors.

## Outputs

- Produce chart-ready data only after validating columns.
- Use `share_artifact` for generated reports, converted files, or chart specs the user should inspect.
