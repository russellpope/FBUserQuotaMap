<#
.SYNOPSIS
    Maps FlashBlade quota UIDs/GIDs to Active Directory user and group names.

.DESCRIPTION
    Connects to a Pure Storage FlashBlade via REST API, retrieves user and group
    quota information, and maps UNIX UIDs/GIDs to Active Directory names.

.PARAMETER Array
    The hostname or IP address of the FlashBlade.

.PARAMETER ApiToken
    The API token used to authenticate with the FlashBlade.

.PARAMETER FileSystem
    The name of the file system to query usage for.

.EXAMPLE
    ./MapQuotaUidToUserNames.ps1 -Array fb01.example.com -ApiToken "T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -FileSystem myfs01
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Array,

    [Parameter(Mandatory = $true)]
    [string]$ApiToken,

    [Parameter(Mandatory = $true)]
    [string]$FileSystem
)

# FlashBlade uses self-signed certs by default; allow untrusted certs for REST calls
if ($PSVersionTable.PSEdition -eq "Core") {
    $script:SkipCertParam = @{ SkipCertificateCheck = $true }
} else {
    # Windows PowerShell 5.x: override certificate validation
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problemIndex) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $script:SkipCertParam = @{}
}

$BaseUrl = "https://$Array"

# --- Authenticate: exchange API token for session token ---
Write-Host "Authenticating to $Array..."
try {
    $LoginResponse = Invoke-WebRequest -Uri "$BaseUrl/api/login" `
        -Method Post `
        -Headers @{ "api-token" = $ApiToken } `
        @script:SkipCertParam

    $Authorization = $LoginResponse.Headers["x-auth-token"]
    if (-not $Authorization) {
        Write-Error "Failed to retrieve x-auth-token from response headers."
        exit 1
    }
    # Headers can come back as arrays; grab the first value if so
    if ($Authorization -is [array]) {
        $Authorization = $Authorization[0]
    }
} catch {
    Write-Error "Authentication failed: $_"
    exit 1
}

Write-Host "Authenticated successfully."

$AuthHeaders = @{ "x-auth-token" = $Authorization }

# --- Helper: call a paginated FB API endpoint and collect all items ---
function Get-AllItems {
    param(
        [string]$Url
    )

    $AllItems = @()
    $NextToken = $null

    do {
        $PageUrl = $Url
        if ($NextToken) {
            $Separator = if ($Url.Contains("?")) { "&" } else { "?" }
            $PageUrl = "$Url${Separator}continuation_token=$NextToken"
        }

        $Response = Invoke-RestMethod -Uri $PageUrl `
            -Method Get `
            -Headers $AuthHeaders `
            @script:SkipCertParam

        if ($Response.items) {
            $AllItems += $Response.items
        }

        $NextToken = $Response.continuation_token
    } while ($NextToken)

    return $AllItems
}

# --- Retrieve user usage ---
Write-Host "Retrieving user usage for file system '$FileSystem'..."
$UserUsage = Get-AllItems -Url "$BaseUrl/api/2.12/usage/users?file_system_names=$FileSystem"
Write-Host "  Found $($UserUsage.Count) user usage entries."

# --- Retrieve group usage ---
Write-Host "Retrieving group usage for file system '$FileSystem'..."
$GroupUsage = Get-AllItems -Url "$BaseUrl/api/2.12/usage/groups?file_system_names=$FileSystem"
Write-Host "  Found $($GroupUsage.Count) group usage entries."

# --- AD lookup helpers using DirectorySearcher ---
function Find-ADUserByUid {
    param([int]$Uid)
    try {
        $Searcher = New-Object DirectoryServices.DirectorySearcher
        $Searcher.Filter = "(&(objectClass=user)(uidNumber=$Uid))"
        $Searcher.PropertiesToLoad.AddRange(@("sAMAccountName", "displayName"))
        $Result = $Searcher.FindOne()
        if ($Result) {
            return @{
                SamAccountName = [string]$Result.Properties["samaccountname"][0]
                DisplayName    = [string]$Result.Properties["displayname"][0]
            }
        }
    } catch {
        Write-Warning "AD user lookup failed for UID ${Uid}: $_"
    }
    return $null
}

function Find-ADGroupByGid {
    param([int]$Gid)
    try {
        $Searcher = New-Object DirectoryServices.DirectorySearcher
        $Searcher.Filter = "(&(objectClass=group)(gidNumber=$Gid))"
        $Searcher.PropertiesToLoad.AddRange(@("sAMAccountName", "displayName"))
        $Result = $Searcher.FindOne()
        if ($Result) {
            return @{
                SamAccountName = [string]$Result.Properties["samaccountname"][0]
                DisplayName    = [string]$Result.Properties["displayname"][0]
            }
        }
    } catch {
        Write-Warning "AD group lookup failed for GID ${Gid}: $_"
    }
    return $null
}

# --- Build user results with AD resolution ---
Write-Host "`nResolving user UIDs against Active Directory..."
$UserResults = foreach ($Entry in $UserUsage) {
    $Uid = $Entry.user.id
    $ResolvedName = $Entry.user.name
    $ADUser = $null
    $SamAccountName = ""
    $DisplayName = ""

    if (-not $ResolvedName) {
        $ADUser = Find-ADUserByUid -Uid $Uid
        if ($ADUser) {
            $ResolvedName = $ADUser.SamAccountName
            $SamAccountName = $ADUser.SamAccountName
            $DisplayName = $ADUser.DisplayName
        }
    } else {
        $SamAccountName = $ResolvedName
    }

    [PSCustomObject]@{
        Type           = "User"
        FileSystem     = $Entry.file_system.name
        UID            = $Uid
        FBName         = $Entry.user.name
        ADUsername      = $SamAccountName
        ADDisplayName  = $DisplayName
        UsageBytes     = $Entry.usage
        UsageGB        = [math]::Round($Entry.usage / 1GB, 2)
        QuotaBytes     = $Entry.quota
        QuotaGB        = if ($Entry.quota) { [math]::Round($Entry.quota / 1GB, 2) } else { $null }
    }
}

# --- Build group results with AD resolution ---
Write-Host "Resolving group GIDs against Active Directory..."
$GroupResults = foreach ($Entry in $GroupUsage) {
    $Gid = $Entry.group.id
    $ResolvedName = $Entry.group.name
    $ADGroup = $null
    $SamAccountName = ""
    $DisplayName = ""

    if (-not $ResolvedName) {
        $ADGroup = Find-ADGroupByGid -Gid $Gid
        if ($ADGroup) {
            $ResolvedName = $ADGroup.SamAccountName
            $SamAccountName = $ADGroup.SamAccountName
            $DisplayName = $ADGroup.DisplayName
        }
    } else {
        $SamAccountName = $ResolvedName
    }

    [PSCustomObject]@{
        Type           = "Group"
        FileSystem     = $Entry.file_system.name
        GID            = $Gid
        FBName         = $Entry.group.name
        ADGroupName    = $SamAccountName
        ADDisplayName  = $DisplayName
        UsageBytes     = $Entry.usage
        UsageGB        = [math]::Round($Entry.usage / 1GB, 2)
        QuotaBytes     = $Entry.quota
        QuotaGB        = if ($Entry.quota) { [math]::Round($Entry.quota / 1GB, 2) } else { $null }
    }
}

# --- Console output ---
Write-Host "`n--- User Usage ---"
$UserResults | Format-Table -AutoSize

Write-Host "--- Group Usage ---"
$GroupResults | Format-Table -AutoSize

# --- CSV export ---
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$UserCsv = "UserUsage_${FileSystem}_${Timestamp}.csv"
$GroupCsv = "GroupUsage_${FileSystem}_${Timestamp}.csv"

$UserResults | Export-Csv -Path $UserCsv -NoTypeInformation
$GroupResults | Export-Csv -Path $GroupCsv -NoTypeInformation

Write-Host "Exported user usage to $UserCsv"
Write-Host "Exported group usage to $GroupCsv"
