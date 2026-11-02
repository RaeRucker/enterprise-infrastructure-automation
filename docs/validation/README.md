# Local validation results

Actual output, captured on 2026-11-02 on Linux with PowerShell 7.4.6, Pester 5.7.1, and PSScriptAnalyzer 1.24.0. All external systems are mocked with synthetic data. CI runs the same suite on Windows as well.

## PSScriptAnalyzer

```text
src/, scripts/ (default rules); examples/, tests/ (documented exclusions in their PSScriptAnalyzerSettings.psd1)
total findings: 0
```

## Pester

```text
Pester v5.7.1
Starting discovery in 1 files.
Discovery found 72 tests in 326ms.
Starting code coverage.
Code Coverage preparation finished after 1691 ms.
Running tests.
Running tests from './tests/InfraOps.Tests.ps1'
Describing Module
  [+] has a valid manifest
  [+] exports only the declared public functions
  [+] Get-InfraOpsConfig has a synopsis, a description, and at least one example
  [+] Get-ServerHealth has a synopsis, a description, and at least one example
  [+] Get-StaleADAccount has a synopsis, a description, and at least one example
  [+] Disable-StaleADAccount has a synopsis, a description, and at least one example
  [+] Get-PrivilegedGroupMembership has a synopsis, a description, and at least one example
  [+] Get-RemoteSessionAudit has a synopsis, a description, and at least one example
  [+] Test-DnsConsistency has a synopsis, a description, and at least one example
  [+] Get-TlsCertificateExpiry has a synopsis, a description, and at least one example
  [+] Get-EntraGuestAccessReport has a synopsis, a description, and at least one example
  [+] Get-AzVmRetirementReport has a synopsis, a description, and at least one example
  [+] Export-InfraReport has a synopsis, a description, and at least one example
  [+] requires confirmation for destructive commands
Describing Get-InfraOpsConfig
  [+] returns safe defaults without a file
  [+] merges a configuration file over the defaults
Describing Get-ServerHealth
  [+] reports Healthy when every metric is within thresholds
  [+] reports Critical when a disk is below the critical threshold
  [+] reports Warning for stopped automatic services, ignoring known trigger-start services
  [+] reports a pending reboot and missing recent updates
  [+] returns Unreachable for a host that fails, and continues with the rest
  [+] always closes the CIM session
Describing Get-StaleADAccount
  [+] returns enabled accounts inactive beyond the threshold, including never-used ones
  [+] excludes new accounts, disabled accounts, and recently active accounts
  [+] flags non-expiring passwords as likely service accounts
  [+] rejects an inactivity window shorter than the lastLogonTimestamp replication interval
Describing Disable-StaleADAccount
  [+] changes nothing with -WhatIf
  [+] disables, records who and why, and moves to the quarantine OU
  [+] skips accounts with non-expiring passwords unless explicitly included
  [+] stops at MaxCount
  [+] only accepts objects produced by Get-StaleADAccount
Describing Get-PrivilegedGroupMembership
  [+] flags non-expiring, old, stale, and disabled members
Describing Remote session parsing
  [+] parses every session row
  [+] handles a blank SESSIONNAME column for disconnected sessions
  [+] parses active sessions, idle formats, and the current-session marker
  [+] returns nothing when no users are logged on
  [+] Get-RemoteSessionAudit flags only disconnected sessions past the idle threshold
Describing Test-DnsConsistency
  [+] passes when all servers agree with the expected address
  [+] detects servers that disagree (stale record on one server)
  [+] reports a server that does not answer
Describing Get-TlsCertificateExpiry
  [+] classifies OK for a certificate expiring in 200 days with errors "None"
  [+] classifies Warning for a certificate expiring in 20 days with errors "None"
  [+] classifies Critical for a certificate expiring in 3 days with errors "None"
  [+] classifies Critical for a certificate expiring in -5 days with errors "None"
  [+] classifies NameMismatch for a certificate expiring in 200 days with errors "RemoteCertificateNameMismatch"
  [+] classifies Untrusted for a certificate expiring in 200 days with errors "RemoteCertificateChainErrors"
  [+] parses host:port and defaults to 443
  [+] returns Unreachable instead of throwing
  [+] rejects malformed endpoints
Describing Get-EntraGuestAccessReport
  [+] classifies guests by invitation state and sign-in recency
Describing Get-AzVmRetirementReport
  [+] maps Standard_DS3_v2 to Dsv2
  [+] maps Standard_DS12_v2_Promo to Dsv2
  [+] maps Standard_D2_v2 to Dv2
  [+] maps Standard_B2ms to B (v1)
  [+] maps Standard_A4_v2 to Av2
  [+] maps Standard_F8s_v2 to Fsv2
  [+] maps Standard_GS4-8 to Gs
  [+] maps Standard_L8s_v2 to Lsv2
  [+] maps Standard_E16-4s_v3 to Esv3
  [+] does not flag current-generation size Standard_B2s_v2
  [+] does not flag current-generation size Standard_D4s_v5
  [+] does not flag current-generation size Standard_D4ds_v5
  [+] does not flag current-generation size Standard_E4as_v6
  [+] does not flag current-generation size Standard_L8s_v3
  [+] marks a series Retired once its date has passed
  [+] excludes end-of-life series unless requested
Describing Export-InfraReport
  [+] HTML-encodes collected values so they cannot inject markup
  [+] highlights Critical rows
  [+] flattens arrays for CSV and keeps them as arrays in JSON
  [+] rejects unsupported formats
  [+] writes nothing with -WhatIf
Describing Logging
  [+] writes structured JSON lines when a log path is configured
Tests completed in 6.67s
Tests Passed: 72, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
Processing code coverage result.
Code Coverage result processed in 1551 ms.
Covered 75.75% / 75%. 800 analyzed Commands in 17 Files.
Code coverage: 75.8% of 800 analyzed commands
```

Uncovered lines are mainly the thin wrappers that call real systems (CIM, ActiveDirectory, quser.exe, Resolve-DnsName, Microsoft Graph, Search-AzGraph, the TLS handshake). Unit tests deliberately mock them.

## Example output

[`examples/output/`](../../examples/output/) was produced by [`examples/New-ExampleOutput.ps1`](../../examples/New-ExampleOutput.ps1). It runs the real public functions against a synthetic environment.

## Not yet validated

| Check | Status |
|---|---|
| Against real Windows Server, Active Directory, DNS, Entra ID, and Azure | Not run. Wrappers follow documented cmdlet behavior; field testing is listed under future improvements. |
