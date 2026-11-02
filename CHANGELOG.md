# Changelog

## 0.2.0

This release requires Zig 0.17.0 and jsonschema 0.3.0. It drops Zig 0.16.0 support.

The router, parameter decoder, and OpenAPI emitter use the new reflection APIs. Existing handler APIs are unchanged. HTTP QUERY is recognized, with a regression test for raw routes. Raw routes remain excluded from OpenAPI 3.1 documents.

The SSR and Dusty examples pin compatible Zio, Dusty, and Zt revisions. They retain the existing test coverage and optional I/O runtimes.

Packages include their license, tests, and examples. Dependency revisions and Zig-generated hashes are committed. The package fingerprint is unchanged.
