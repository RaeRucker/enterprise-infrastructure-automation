# Security

## Design principles

| Principle | Implementation |
|---|---|
| Read-only by default | 10 of 11 public functions only read. The one state-changing function (`Disable-StaleADAccount`) uses `ConfirmImpact = 'High'`, supports `-WhatIf`, and accepts only objects produced by `Get-StaleADAccount`. |
| Reversible changes | Accounts are disabled, never deleted. The description records date, operator, and reason. Reverse with `Enable-ADAccount`. |
| Blast-radius limits | `-MaxCount` (default 50) stops a bulk disable. Accounts with non-expiring passwords (usually service accounts) are skipped unless `-IncludeNonExpiringPasswords`. |
| No stored credentials | Functions use the caller's identity, or a `[pscredential]` passed at runtime. The scheduled script is meant to run as a group Managed Service Account, which has no password to store. |
| Configuration as data | `.psd1` config files are read with `Import-PowerShellDataFile`, which parses them without executing code. |
| Input validation | Computer names, endpoints, OUs, day ranges, and report paths are validated with `ValidatePattern` / `ValidateRange` before any connection is made. |
| Safe output | HTML reports encode every value, so collected data (service names, certificate subjects, AD descriptions) can't inject script. A unit test checks this with a `<script>` payload. |
| Audit trail | Every action and every skip is written as structured JSON Lines when `Logging.Path` is set. |

## Least-privilege permissions by function

| Function | Minimum rights |
|---|---|
| `Get-ServerHealth` | WinRM access plus WMI read on targets (*Remote Management Users* + WMI namespace permissions, or local admin) |
| `Get-StaleADAccount`, `Get-PrivilegedGroupMembership` | Authenticated user in the domain (default AD read) |
| `Disable-StaleADAccount` | Delegated *Disable account* and *Write description* (and *Move* if quarantining) on the target OUs only. Not Domain Admin. |
| `Get-RemoteSessionAudit` | Session query rights on targets |
| `Test-DnsConsistency` | Network access to DNS servers (UDP/TCP 53) |
| `Get-TlsCertificateExpiry` | Network access to the endpoints |
| `Get-EntraGuestAccessReport` | Microsoft Graph `User.Read.All`, `AuditLog.Read.All` (read-only); Entra ID P1/P2 for sign-in activity |
| `Get-AzVmRetirementReport` | Azure *Reader* on the subscriptions |

## Handling the output

Reports contain server names, account names, group memberships, and patch levels. Treat them as internal data. Store them on an access-controlled share. Don't email them outside the organization. `output/` and `logs/` are git-ignored.

## Threats considered

| Threat | Mitigation |
|---|---|
| A bulk disable takes out service accounts | Non-expiring passwords are skipped by default; `-MaxCount`; confirmation prompts; `-WhatIf` |
| Stale-account false positives (replication lag) | `InactiveDays` minimum of 14, matching the `lastLogonTimestamp` sync interval; documented in help |
| Report used for cross-site scripting | HTML encoding, with a test |
| Credentials leaked in scripts or task definitions | No credential parameters persisted; gMSA guidance; gitleaks in CI |
| Tampered configuration file executing code | Data-file parsing only |
