param(
    [string]$WorkDir = $PSScriptRoot,
    [string]$Token = $env:TENCENT_DOCS_TOKEN
)

$mcpUrl = "https://docs.qq.com/openapi/mcp"
$headers = @{ "Authorization" = $Token; "Content-Type" = "application/json" }
$excludeNames = @()
$script:apiCalls = 0

# Load existing progress
$progressFile = Join-Path $WorkDir "data\01-progress.json"
if (Test-Path $progressFile) {
    $progress = Get-Content $progressFile -Encoding UTF8 | ConvertFrom-Json
    $script:apiCalls = $progress.api_calls_used
}
$apiLimit = 1800

function Call-MCP {
    param([string]$ToolName, [hashtable]$Arguments = @{})

    $script:apiCalls++

    # Build JSON body manually to avoid PowerShell string issues
    $argsJson = "{"
    $first = $true
    foreach ($key in $Arguments.Keys) {
        if (-not $first) { $argsJson += "," }
        $val = $Arguments[$key]
        if ($val -is [string]) {
            $escaped = $val.Replace('\', '\\').Replace('"', '\"')
            $argsJson += """$key"":""$escaped"""
        } elseif ($val -is [int] -or $val -is [long]) {
            $argsJson += """$key"":$val"
        }
        $first = $false
    }
    $argsJson += "}"

    $requestId = Get-Date -Format "ffffff"
    $body = "{""jsonrpc"":""2.0"",""id"":$requestId,""method"":""tools/call"",""params"":{""name"":""$ToolName"",""arguments"":$argsJson}}"

    try {
        $response = Invoke-RestMethod -Uri $mcpUrl -Method Post -Headers $headers -Body $body -TimeoutSec 30
        $text = $response.result.content[0].text
        $data = $text | ConvertFrom-Json
        return $data
    } catch {
        Write-Host "ERROR calling $ToolName $argsJson : $_"
        return $null
    }
}

function Scan-Folder {
    param([string]$FolderId, [string]$FolderPath, [int]$Depth = 0)

    if ($script:apiCalls -ge ($apiLimit - 50)) {
        Write-Host "WARNING: Approaching API limit ($script:apiCalls / $apiLimit)"
        return $null
    }

    $indent = "  " * $Depth
    Write-Host "$indent[SCAN] $FolderPath"

    $items = Call-MCP -ToolName "manage.folder_list" -Arguments @{ folder_id = $FolderId }
    if (-not $items) {
        return @{ error = "Failed to list $FolderId" }
    }

    $result = @{ folder_id = $FolderId; folder_path = $FolderPath; folders = @(); files = @() }

    $list = if ($items.list) { $items.list } else { $items }
    if (-not $list) { return $result }

    foreach ($item in $list) {
        if (-not $item) { continue }

        $name = if ($item.title) { $item.title } else { $item.name }
        $id = $item.id
        $isFolder = ($item.is_folder -eq $true)

        if ($script:apiCalls -ge ($apiLimit - 50)) {
            return $result
        }

        if ($isFolder) {
            if ($excludeNames -contains $name) {
                Write-Host "$indent  [SKIP] $name"
                continue
            }
            $childPath = "$FolderPath/$name"
            $subResult = Scan-Folder -FolderId $id -FolderPath $childPath -Depth ($Depth + 1)
            if ($subResult) {
                $result.folders += $subResult
            }
        } else {
            Write-Host "$indent  [FILE] $name"
            $result.files += @{ file_id = $id; file_name = $name; folder_path = $FolderPath }
        }
    }

    return $result
}

# --- MAIN ---
Write-Host "=== Tree Scan ==="
Write-Host "API calls so far: $script:apiCalls"
Write-Host "Excluding: $($excludeNames -join ', ')"

# Root folders：从 data\02-root-folder-list.json 读取（首步产物，格式见 README）
$rootFolders = @()
$rootJsonFile = Join-Path $WorkDir "data\02-root-folder-list.json"
if (Test-Path $rootJsonFile) {
    $raw = Get-Content $rootJsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($it in $raw.list) {
        if ($it.is_folder) { $rootFolders += @{ id = $it.id; name = $it.title } }
    }
} else {
    Write-Host "[FATAL] 未找到 $rootJsonFile，请先获取根目录列表"
    exit 1
}

$fullTree = @()
foreach ($folder in $rootFolders) {
    $r = Scan-Folder -FolderId $folder.id -FolderPath $folder.name
    if ($r) { $fullTree += $r }
}

# Save tree
$treeJson = $fullTree | ConvertTo-Json -Depth 10
$treeFile = Join-Path $WorkDir "data\03-file-tree.json"
$treeJson | Set-Content -Path $treeFile -Encoding UTF8

# Count
$totalFiles = 0
$totalFolders = 0
function Count-Items($nodes) {
    foreach ($n in $nodes) {
        $global:totalFiles += $n.files.Count
        $global:totalFolders++
        if ($n.folders) { Count-Items $n.folders }
    }
}
Count-Items $fullTree

Write-Host "=== Done ==="
Write-Host "Folders: $totalFolders, Files: $totalFiles, API calls: $script:apiCalls"

# Update progress
$progress.api_calls_used = $script:apiCalls
$progress.last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$progress.tree_scanned = $true
$progress.total_files = $totalFiles
$progress.total_folders = $totalFolders
$progress | ConvertTo-Json -Depth 5 | Set-Content -Path $progressFile -Encoding UTF8
