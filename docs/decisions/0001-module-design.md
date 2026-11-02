# ADR 0001: One module with thin data-access wrappers

Status: Accepted

## Context

Operational scripts usually grow as standalone `.ps1` files. Each one reimplements connection handling, logging, thresholds, and output, and none can be tested without a live domain or server.

## Decision

- One module (`InfraOps`) with a manifest that exports only public functions. Everything else is private.
- Every call to an external system goes through a private wrapper (`Invoke-InfraCimQuery`, `Get-InfraADAccount`, `Invoke-InfraQuser`, `Resolve-InfraDnsName`, `Get-InfraEntraGuest`, `Invoke-InfraResourceGraph`, `Get-InfraRemoteCertificate`). The wrappers contain no logic. The public functions contain all of it.
- Structured output with a type name (`InfraOps.ServerHealth`, ...) instead of formatted text, so results can be piped, filtered, exported, or sent to a monitoring system.
- Partial failure is data, not an exception. An unreachable server returns a result with `Status = Unreachable` rather than stopping the run.

## Consequences

- The decision logic (thresholds, classification, parsing, safeguards) is unit-tested on any OS with mocks: 72 tests, about 76% command coverage. The uncovered remainder is mostly the wrappers.
- Wrappers are where real-environment bugs will appear (cmdlet behavior, permissions, locale). Field testing against real systems is still required. See [Limitations](../../README.md#limitations-and-known-gaps).
- `Set-StrictMode -Version Latest` in the module surfaced real defects during development: missing optional properties on Graph objects, and pipeline-unrolled arrays. The wrappers and `Get-InfraOptionalProperty` now handle those explicitly.
