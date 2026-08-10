[CmdletBinding()]
param(
    [switch]$WithObservability,
    [switch]$Check,
    [switch]$Update,
    [switch]$SkipDockerInstall,
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
Usage:
  .\setup.ps1 [options]

Windows uses local/IP:port mode. DNS + HTTPS ingress is intentionally managed
by setup.sh on Ubuntu servers.

Options:
  -WithObservability  Start Prometheus, Grafana, node-exporter, and cAdvisor.
  -Check              Validate configuration and check an existing deployment.
  -Update             Pull newer images, rebuild Jenkins, and apply the stack.
  -SkipDockerInstall  Fail instead of installing Docker Desktop when unavailable.
  -Help               Show this help message.
'@ | Write-Host
    exit 0
}

if ($Check -and $Update) {
    throw 'Use either -Check or -Update, not both.'
}

if ($env:OS -ne 'Windows_NT') {
    throw 'setup.ps1 supports Windows only. Use setup.sh on Ubuntu.'
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptRoot '.env'
$EnvExample = Join-Path $ScriptRoot '.env.example'
$StackMode = if ($WithObservability) { 'observability' } else { 'core' }

$script:ComposeFiles = @(
    '-f', (Join-Path $ScriptRoot 'compose.yaml')
)
if ($WithObservability) {
    $script:ComposeFiles += @('-f', (Join-Path $ScriptRoot 'compose.observability.yaml'))
}
$script:ComposeFiles += @('-f', (Join-Path $ScriptRoot 'compose.local.yaml'))

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[compose-stack] $Message"
}

function Test-DockerCli {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker compose version *> $null
    return $LASTEXITCODE -eq 0
}

function Test-DockerDaemon {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    return $LASTEXITCODE -eq 0
}

function Add-DockerCliToPath {
    $path = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
    if ((Test-Path $path) -and ($env:Path -notlike "*$path*")) {
        $env:Path = "$path;$env:Path"
    }
}

function Install-DockerDesktop {
    if ($SkipDockerInstall) {
        throw 'Docker Desktop is unavailable and automatic installation was disabled.'
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Install Docker Desktop manually or install winget, then rerun this script.'
    }
    Write-Log 'Installing Docker Desktop with winget.'
    & winget install --id Docker.DockerDesktop --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Docker Desktop installation failed with exit code $LASTEXITCODE." }
    Add-DockerCliToPath
}

function Start-DockerDesktop {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )
    $executable = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $executable) { throw 'Docker Desktop could not be located.' }
    Start-Process -FilePath $executable
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        if (Test-DockerDaemon) { return }
        Start-Sleep -Seconds 2
    }
    throw 'Docker Desktop did not become ready.'
}

function Ensure-Docker {
    Add-DockerCliToPath
    if (-not (Test-DockerCli)) {
        if ($Check) { throw 'Docker Desktop and Docker Compose are required for -Check.' }
        Install-DockerDesktop
    }
    if (-not (Test-DockerDaemon)) {
        if ($Check) { throw 'Docker Desktop is not running.' }
        Start-DockerDesktop
    }
    $osType = (& docker info --format '{{.OSType}}' 2>$null | Select-Object -First 1).Trim()
    if ($osType -ne 'linux') { throw "Docker Desktop must use Linux containers. Current OSType: '$osType'." }
}

function Read-EnvValue {
    param([string]$Name, [string]$Fallback)
    if (-not (Test-Path $EnvFile)) { return $Fallback }
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line.StartsWith("$Name=")) {
            $value = $line.Substring($Name.Length + 1).Trim().Trim('"')
            if ($value) { return $value }
            break
        }
    }
    return $Fallback
}

function Set-EnvValue {
    param([string]$Name, [string]$Value)
    $lines = [System.Collections.Generic.List[string]]::new()
    $replaced = $false
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line.StartsWith("$Name=")) {
            $lines.Add("$Name=$Value")
            $replaced = $true
        } else {
            $lines.Add($line)
        }
    }
    if (-not $replaced) { $lines.Add("$Name=$Value") }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($EnvFile, $lines.ToArray(), $utf8)
}

function New-SecurePassword {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Ensure-Environment {
    if (-not (Test-Path $EnvExample)) { throw "Missing $EnvExample" }
    if (-not (Test-Path $EnvFile)) {
        Copy-Item $EnvExample $EnvFile
        Write-Log 'Created .env from .env.example.'
    }

    $hostHome = Read-EnvValue 'HOST_HOME' '/srv/jenkins/home'
    if ($hostHome -eq '/srv/jenkins/home') {
        $windowsHome = (Join-Path $ScriptRoot 'data\jenkins-home').Replace('\', '/')
        Set-EnvValue 'HOST_HOME' $windowsHome
    }

    if ($WithObservability) {
        $password = Read-EnvValue 'GRAFANA_ADMIN_PASSWORD' 'change-me'
        if ([string]::IsNullOrWhiteSpace($password) -or $password -eq 'change-me') {
            Set-EnvValue 'GRAFANA_ADMIN_PASSWORD' (New-SecurePassword)
            Write-Log 'Generated Grafana admin password in .env.'
        }
    }
}

function Prepare-HostHome {
    $hostHome = Read-EnvValue 'HOST_HOME' ''
    if ($hostHome -notmatch '^[A-Za-z]:[\\/]') {
        throw "HOST_HOME must be an absolute Windows path. Current value: '$hostHome'."
    }
    New-Item -ItemType Directory -Path ([System.IO.Path]::GetFullPath($hostHome)) -Force | Out-Null
}

function Invoke-Compose {
    param([string[]]$Arguments, [switch]$Capture, [switch]$AllowFailure)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & docker compose --env-file $EnvFile @script:ComposeFiles @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if (-not $Capture -and $output) { $output | ForEach-Object { Write-Host $_ } }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ($Capture -and $output) { $output | ForEach-Object { Write-Host $_ } }
        throw "Docker Compose failed: $($Arguments -join ' ')"
    }
    if ($Capture) { return $output }
}

$ExpectedServices = @('docker', 'jenkins', 'nginx')
if ($WithObservability) { $ExpectedServices += @('prometheus', 'grafana', 'node-exporter', 'cadvisor') }

function Get-ServiceState {
    param([string]$Service)
    $id = Invoke-Compose -Arguments @('ps', '-q', $Service) -Capture -AllowFailure
    $id = ($id | Select-Object -First 1)
    if (-not $id) { return 'missing' }
    $state = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $id 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $state) { return 'missing' }
    return ($state | Select-Object -First 1).Trim()
}

function Wait-ForServices {
    foreach ($service in $ExpectedServices) {
        $state = 'missing'
        for ($attempt = 1; $attempt -le 60; $attempt++) {
            $state = Get-ServiceState $service
            if ($state -in @('healthy', 'running')) { break }
            Start-Sleep -Seconds 2
        }
        if ($state -notin @('healthy', 'running')) { throw "Service '$service' did not become ready." }
        Write-Log "Service '$service' is $state."
    }
}

function Wait-ForHttp {
    param([string]$Name, [string]$Uri)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                Write-Log "$Name endpoint is ready: $Uri"
                return
            }
        } catch {}
        Start-Sleep -Seconds 2
    }
    throw "$Name endpoint did not become ready: $Uri"
}

function Test-Endpoints {
    Wait-ForHttp 'Jenkins' "http://127.0.0.1:$(Read-EnvValue 'NGINX_HTTP_PORT' '9000')/login"
    if ($WithObservability) {
        Wait-ForHttp 'Prometheus' "http://127.0.0.1:$(Read-EnvValue 'PROMETHEUS_PORT' '9090')/-/ready"
        Wait-ForHttp 'Grafana' "http://127.0.0.1:$(Read-EnvValue 'GRAFANA_PORT' '3030')/api/health"
    }
}

function Show-Summary {
    Write-Host ''
    Write-Host 'Compose Stack is ready.'
    Write-Host "  Jenkins through Nginx: http://localhost:$(Read-EnvValue 'NGINX_HTTP_PORT' '9000')"
    Write-Host "  Jenkins direct:        http://localhost:$(Read-EnvValue 'JENKINS_HTTP_PORT' '49000')"
    if ($WithObservability) {
        Write-Host "  Prometheus:            http://localhost:$(Read-EnvValue 'PROMETHEUS_PORT' '9090')"
        Write-Host "  Grafana:               http://localhost:$(Read-EnvValue 'GRAFANA_PORT' '3030')"
    }
}

Set-Location $ScriptRoot
Ensure-Docker

if ($Check) {
    if (-not (Test-Path $EnvFile)) { throw 'Missing .env. Run setup.ps1 first.' }
    Invoke-Compose -Arguments @('config', '--quiet')
    Wait-ForServices
    Test-Endpoints
    Show-Summary
    exit 0
}

Ensure-Environment
Prepare-HostHome
Invoke-Compose -Arguments @('config', '--quiet')

if ($Update) {
    Invoke-Compose -Arguments @('pull', '--ignore-buildable')
    Invoke-Compose -Arguments @('build', '--pull', 'jenkins')
}

Write-Log "Starting the $StackMode stack in local mode."
if ($Update) {
    Invoke-Compose -Arguments @('up', '--detach')
} else {
    Invoke-Compose -Arguments @('up', '--detach', '--build')
}
Invoke-Compose -Arguments @('restart', 'nginx')
Wait-ForServices
Test-Endpoints
Show-Summary
