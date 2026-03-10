# FlashBlade Quota UID Mapper

Maps Pure Storage FlashBlade quota UIDs/GIDs to Active Directory user and group names.

## Overview

When FlashBlade tracks per-user and per-group quota usage, it stores UNIX UIDs and GIDs. This script queries the FlashBlade REST API for quota usage data, resolves those UIDs/GIDs to human-readable Active Directory names, and exports the results to CSV.

## Prerequisites

- **PowerShell 5.1+** (Windows PowerShell) or **PowerShell 7+** (pwsh / PowerShell Core)
- Network access to the FlashBlade management interface
- A FlashBlade **API token** with read access to quota data
- **Active Directory** — the machine running the script must be domain-joined (or have line-of-sight to a domain controller) so that `DirectorySearcher` lookups for `uidNumber` and `gidNumber` can succeed

## Usage

```powershell
./MapQuotaUidToUserNames.ps1 -Array <FlashBlade> -ApiToken <Token> -FileSystem <Name>
```

### Parameters

| Parameter    | Required | Description                                          |
|--------------|----------|------------------------------------------------------|
| `-Array`     | Yes      | Hostname or IP address of the FlashBlade             |
| `-ApiToken`  | Yes      | API token for FlashBlade authentication              |
| `-FileSystem`| Yes      | Name of the file system to query usage for           |

### Example

```powershell
./MapQuotaUidToUserNames.ps1 `
    -Array fb01.example.com `
    -ApiToken "T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -FileSystem myfs01
```

## What It Does

1. **Authenticates** to the FlashBlade REST API (v2.12) using the provided API token
2. **Retrieves user quota usage** for the specified file system (handles pagination automatically)
3. **Retrieves group quota usage** for the specified file system
4. **Resolves UIDs/GIDs** — for any entry where FlashBlade does not already provide a name, performs an Active Directory lookup via `DirectorySearcher` using `uidNumber` / `gidNumber` attributes
5. **Displays results** in the console as formatted tables
6. **Exports to CSV** — writes two timestamped CSV files to the current directory

## Console Output

```
Authenticating to fb01.example.com...
Authenticated successfully.
Retrieving user usage for file system 'myfs01'...
  Found 12 user usage entries.
Retrieving group usage for file system 'myfs01'...
  Found 5 group usage entries.

Resolving user UIDs against Active Directory...

--- User Usage ---

Type FileSystem UID  FBName   ADUsername ADDisplayName UsageBytes  UsageGB QuotaBytes QuotaGB
---- ---------- ---  ------   --------- ------------- ----------  ------- ---------- -------
User myfs01     1001 jdoe     jdoe                    10737418240 10.00   53687091200 50.00
User myfs01     1002          asmith    Alice Smith   5368709120   5.00   53687091200 50.00

--- Group Usage ---

Type  FileSystem GID  FBName    ADGroupName ADDisplayName UsageBytes   UsageGB QuotaBytes  QuotaGB
----  ---------- ---  ------    ----------- ------------- ----------   ------- ----------  -------
Group myfs01     2001 engineers engineers                 32212254720  30.00   107374182400 100.00
```

- **FBName** — the name FlashBlade already has on record (may be blank for unmapped UIDs/GIDs)
- **ADUsername / ADGroupName** — resolved via Active Directory lookup when FBName is blank
- **ADDisplayName** — the AD `displayName` attribute (populated only for AD-resolved entries)
- **UsageGB / QuotaGB** — usage and quota converted to gigabytes (QuotaGB is blank if no quota is set)

## CSV Output

Two files are written to the working directory:

```
UserUsage_myfs01_20260225-143022.csv
GroupUsage_myfs01_20260225-143022.csv
```

The filename format is `{Type}Usage_{FileSystem}_{yyyyMMdd-HHmmss}.csv`.

### User CSV columns

`Type, FileSystem, UID, FBName, ADUsername, ADDisplayName, UsageBytes, UsageGB, QuotaBytes, QuotaGB`

### Group CSV columns

`Type, FileSystem, GID, FBName, ADGroupName, ADDisplayName, UsageBytes, UsageGB, QuotaBytes, QuotaGB`

## Notes

- **Self-signed certificates** — FlashBlade commonly uses self-signed TLS certificates. The script handles this automatically on both PowerShell Core (`-SkipCertificateCheck`) and Windows PowerShell 5.x (custom certificate policy).
- **Pagination** — the script follows FlashBlade API continuation tokens, so it works regardless of how many quota entries exist.
- **AD lookups** — if an AD lookup fails (e.g., no matching `uidNumber`/`gidNumber` in the directory), a warning is printed and the entry is included in the output with blank AD fields.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
