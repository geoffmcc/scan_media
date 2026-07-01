param(
  [Alias("Host")]
  [string]$HostName = "",
  [string]$InitialUser = "",
  [string]$RepoUrl = "",
  [string]$RuntimeUser = "scanmedia",
  [string]$ReadonlyGroup = "scanmedia_ro",
  [string]$RemoteMediaMount = "/media/Media",
  [string]$RemoteMediaRoot = "/media/Media/Video",
  [string]$RemoteQueue = "/var/lib/scan_media/changed-files.queue",
  [string]$SshKey = ""
)

$ErrorActionPreference = "Stop"
$TargetHost = if ($HostName) { $HostName } else { Read-Host "Jellyfin server LAN IP/host" }
if (-not $TargetHost) { throw "Host is required" }
if (-not $InitialUser) { $InitialUser = Read-Host "Initial SSH user with sudo on $TargetHost" }
if (-not $InitialUser) { throw "Initial user is required" }

$ProjectDir = $PSScriptRoot
$Bootstrap = Join-Path $ProjectDir "watch_media\bootstrap_server.sh"
if (-not (Test-Path $Bootstrap)) { throw "Bootstrap not found: $Bootstrap" }

if (-not $RepoUrl) {
  $RepoUrl = (& git -C $ProjectDir remote get-url origin 2>$null)
  if (-not $RepoUrl) { $RepoUrl = "https://github.com/geoffmcc/scan_media.git" }
}

if (-not $SshKey) { $SshKey = Join-Path $env:USERPROFILE ".ssh\scan_media_watcher" }
$PubKey = "$SshKey.pub"
if (-not (Test-Path $SshKey) -or -not (Test-Path $PubKey)) {
  Write-Host "Generating SSH key: $SshKey"
  $keyDir = Split-Path $SshKey -Parent
  if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir | Out-Null }
  ssh-keygen -t ed25519 -f "$SshKey" -N "" -q
}
$PublicKey = (Get-Content $PubKey -Raw).Trim()

$ControlPath = Join-Path $env:TEMP "scan-media-ssh-%r@%h-%p"
Write-Host "Opening SSH connection to $InitialUser@$TargetHost. Enter password if prompted."
ssh -M -o "ControlPath=$ControlPath" -o "ControlPersist=60" -o "StrictHostKeyChecking=accept-new" -fN "$InitialUser@$TargetHost"
if ($LASTEXITCODE -ne 0) { throw "Failed to open SSH control connection" }

try {
  scp -o "ControlPath=$ControlPath" "$Bootstrap" "$InitialUser@$TargetHost`:/tmp/scan_media_bootstrap_server.sh"
  if ($LASTEXITCODE -ne 0) { throw "Failed to upload bootstrap" }

  $remoteArgs = @(
    "sudo", "bash", "/tmp/scan_media_bootstrap_server.sh", "--yes",
    "--repo-url", $RepoUrl,
    "--runtime-user", $RuntimeUser,
    "--readonly-group", $ReadonlyGroup,
    "--remote-media-mount", $RemoteMediaMount,
    "--remote-media-root", $RemoteMediaRoot,
    "--remote-queue", $RemoteQueue,
    "--ssh-key", $PublicKey
  )
  $remoteCommand = ($remoteArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join " "
  ssh -t -o "ControlPath=$ControlPath" "$InitialUser@$TargetHost" $remoteCommand
  if ($LASTEXITCODE -ne 0) { throw "Remote bootstrap failed" }
} finally {
  ssh -o "ControlPath=$ControlPath" -O exit "$InitialUser@$TargetHost" 2>$null | Out-Null
}

Write-Host "Verifying key-based SSH as $RuntimeUser@$TargetHost"
ssh -i "$SshKey" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$RuntimeUser@$TargetHost" "echo OK"
if ($LASTEXITCODE -ne 0) { throw "Could not SSH as $RuntimeUser" }

Write-Host "Verifying watcher service"
ssh -i "$SshKey" -o BatchMode=yes "$RuntimeUser@$TargetHost" "systemctl is-active scan-media-watcher && systemctl status --no-pager scan-media-watcher | sed -n '1,12p'"
