# ADR 001: Keep schema mechanics in Kochab

- Status: Accepted
- Date: 2026-09-15

## Context

Applications need typed settings, defaults, source-located validation errors,
layer merging, and metadata for settings interfaces. Kochab already owns the
JSONC document tree and its byte-range queries.

## Decision

Kochab provides the schema mechanism: field metadata, a definition DSL,
validation against `Document`, defaults, layer merging, and a settings-oriented
JSON Schema importer. Application-specific keys and layer ordering remain in
the application.

Layers merge from left to right. Objects merge recursively and arrays replace.
If a later value violates its field, only that value is ignored, preserving the
earlier valid value. DSL schemas retain unknown fields so extensions can own
their settings. Imported JSON Schemas honor `additionalProperties`.

## Consequences

Validation diagnostics can use `Document#range_of` directly and remain useful
for both file annotations and settings interfaces. Kochab gains no runtime
dependency and does not learn application-specific settings.
