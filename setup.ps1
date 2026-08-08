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

Options:
  -WithObservability  Start Prometheus, Grafana, node-exporter, and cAdvisor.
  -Check              Validate configuration and check an existing deployment.
  -Update             Pull newer images, rebuild Jenkins, and apply the stack.
  -SkipDockerInstall  Fail instead of installing Docker Desktop when unavailable.
  -Help               Show this help message.

Examples:
  .\setup.ps1
  .\setup.ps1 -WithObservability
  .\setup.ps1 -WithObservability -Check
  .\setup.ps1 -WithObservability -Update
'@ | Write-Host
    exit 0
}

if ($Check -and $Update) {
    throw 'Use either -Check or -Update, not both.'
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptRoot '.env'
$EnvExample = Join-Path $ScriptRoot '.env.example'
$StackMode = if ($WithObservability) { 'observability' } else { 'core' }
$Action = if ($Check) { 'check' } elseif ($Update) { 'update' } else { 'setup' }

$script:ComposeFiles = @('-f', (Join-Path $ScriptRoot 'compose.yaml'))
if ($WithObservability) {
    $script:ComposeFiles += @('-f', (Join-Path $ScriptRoot 'compose.observability.yaml'))
}

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[compose-stack] $Message"
}

function Write-WarningMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Warning "[compose-stack] $Message"
}

function Test-DockerCli {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }

    & docker compose version *> $null
    return $LASTEXITCODE -eq 0
}

function Test-DockerDaemon {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }

    & docker info *> $null
    return $LASTEXITCODE -eq 0
}

function Add-DockerCliToPath {
    $dockerCliDirectory = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
    if ((Test-Path $dockerCliDirectory) -and ($env:Path -notlike "*$dockerCliDirectory*")) {
        $env:Path = "$dockerCliDirectory;$env:Path"
    }
}

function Install-DockerDesktop {
    if ($SkipDockerInstall) {
        throw 'Docker Desktop is unavailable and automatic installation was disabled.'
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Docker Desktop is unavailable. Install Docker Desktop manually or install winget, then rerun this script.'
    }

    Write-Log 'Installing Docker Desktop with winget. Windows may display a UAC prompt.'
    & winget install --id Docker.DockerDesktop --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Desktop installation failed with exit code $LASTEXITCODE."
    }

    Add-DockerCliToPath
    if (-not (Test-DockerCli)) {
        throw 'Docker Desktop was installed, but the Docker CLI is not available in this session. Restart Windows or reopen PowerShell, then rerun the command.'
    }
}

function Start-DockerDesktop {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )

    $executable = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $executable) {
        throw 'The Docker daemon is unavailable and Docker Desktop could not be located.'
    }

    Write-Log 'Starting Docker Desktop. Complete any first-run prompts shown by Docker Desktop.'
    Start-Process -FilePath $executable

    for ($attempt = 1; $attempt -le 90; $attempt++) {
        if (Test-DockerDaemon) {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw 'Docker Desktop did not become ready within three minutes.'
}

function Assert-LinuxContainers {
    $osTypeOutput = & docker info --format '{{.OSType}}' 2>$null
    $dockerExitCode = $LASTEXITCODE
    $osType = [string]($osTypeOutput | Select-Object -First 1)
    $osType = $osType.Trim().ToLowerInvariant()

    if ($dockerExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($osType)) {
        throw "Unable to determine the Docker container mode. Docker exit code: $dockerExitCode."
    }

    if ($osType -ne 'linux') {
        throw "Docker Desktop must use Linux containers. Current Docker OSType: '$osType'."
    }
}

function Ensure-Docker {
    Add-DockerCliToPath

    if (-not (Test-DockerCli)) {
        if ($Check) {
            throw 'Docker Desktop and the Docker Compose plugin are required for -Check.'
        }
        Install-DockerDesktop
    }

    if (-not (Test-DockerDaemon)) {
        if ($Check) {
            throw 'Docker Desktop is not running. Start it and rerun the check.'
        }
        Start-DockerDesktop
    }

    Assert-LinuxContainers
}

function Read-EnvValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Fallback
    )

    if (-not (Test-Path $EnvFile)) {
        return $Fallback
    }

    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line.StartsWith("$Name=")) {
            $value = $line.Substring($Name.Length + 1).Trim().Trim('"')
            if ($value) {
                return $value
            }
            break
        }
    }

    return $Fallback
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

function Set-EnvValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $replaced = $false

    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line.StartsWith("$Name=")) {
            $lines.Add("$Name=$Value")
            $replaced = $true
        }
        else {
            $lines.Add($line)
        }
    }

    if (-not $replaced) {
        $lines.Add("$Name=$Value")
    }

    Write-Utf8File -Path $EnvFile -Lines $lines.ToArray()
}

function New-SecurePassword {
    $bytes = New-Object byte[] 24
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }

    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Ensure-Environment {
    if (-not (Test-Path $EnvExample)) {
        throw "Missing environment template: $EnvExample"
    }

    if (-not (Test-Path $EnvFile)) {
        Copy-Item -LiteralPath $EnvExample -Destination $EnvFile
        Write-Log 'Created .env from .env.example.'
    }
    else {
        Write-Log 'Keeping the existing .env file.'
    }

    $hostHome = Read-EnvValue -Name 'HOST_HOME' -Fallback '/srv/jenkins/home'
    if ($hostHome -eq '/srv/jenkins/home') {
        $windowsHostHome = (Join-Path $ScriptRoot 'data\jenkins-home').Replace('\', '/')
        Set-EnvValue -Name 'HOST_HOME' -Value $windowsHostHome
        Write-Log "Configured Windows HOST_HOME: $windowsHostHome"
    }

    if ($WithObservability) {
        $grafanaPassword = Read-EnvValue -Name 'GRAFANA_ADMIN_PASSWORD' -Fallback 'change-me'
        if ([string]::IsNullOrWhiteSpace($grafanaPassword) -or $grafanaPassword -eq 'change-me') {
            Set-EnvValue -Name 'GRAFANA_ADMIN_PASSWORD' -Value (New-SecurePassword)
            Write-Log 'Replaced the default Grafana password with a generated value in .env.'
        }
    }
}

function Prepare-HostHome {
    $hostHome = Read-EnvValue -Name 'HOST_HOME' -Fallback ''
    if ($hostHome -notmatch '^[A-Za-z]:[\\/]') {
        throw "HOST_HOME must be an absolute Windows path. Current value: '$hostHome'."
    }

    $fullPath = [System.IO.Path]::GetFullPath($hostHome)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\', '/') -eq $rootPath.TrimEnd('\', '/')) {
        throw "HOST_HOME cannot be a drive root: '$fullPath'."
    }

    New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    Write-Log "Prepared Jenkins shared directory: $fullPath"
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Capture,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 surfaces normal native stderr output as a
        # NativeCommandError when ErrorActionPreference is Stop. Compose uses
        # stderr for progress, so its process exit code is the source of truth.
        $ErrorActionPreference = 'Continue'
        $output = & docker compose --env-file $EnvFile @script:ComposeFiles @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if (-not $Capture -and $output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ($Capture -and $output) {
            $output | ForEach-Object { Write-Host $_ }
        }
        throw "Docker Compose failed with exit code ${exitCode}: $($Arguments -join ' ')"
    }

    if ($Capture) {
        return $output
    }
}

function Validate-Configuration {
    Write-Log "Validating the $StackMode Compose configuration."
    Invoke-Compose -Arguments @('config', '--quiet')
}

$ExpectedServices = @('docker', 'jenkins', 'nginx')
if ($WithObservability) {
    $ExpectedServices += @('prometheus', 'grafana', 'node-exporter', 'cadvisor')
}

function Get-ServiceState {
    param([Parameter(Mandatory)][string]$Service)

    $containerId = Invoke-Compose -Arguments @('ps', '-q', $Service) -Capture -AllowFailure
    $containerId = ($containerId | Select-Object -First 1)
    if (-not $containerId) {
        return 'missing'
    }

    $state = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $state) {
        return 'missing'
    }

    return ($state | Select-Object -First 1).Trim()
}

function Wait-ForServices {
    foreach ($service in $ExpectedServices) {
        $state = 'missing'
        for ($attempt = 1; $attempt -le 60; $attempt++) {
            $state = Get-ServiceState -Service $service
            if ($state -in @('healthy', 'running')) {
                break
            }
            Start-Sleep -Seconds 2
        }

        if ($state -notin @('healthy', 'running')) {
            Invoke-Compose -Arguments @('logs', '--tail', '50', $service) -AllowFailure
            throw "Service '$service' did not become ready. Last state: $state"
        }
        Write-Log "Service '$service' is $state."
    }
}

function Test-Services {
    $failed = $false
    foreach ($service in $ExpectedServices) {
        $state = Get-ServiceState -Service $service
        if ($state -in @('healthy', 'running')) {
            Write-Log "Service '$service' is $state."
        }
        else {
            Write-WarningMessage "Service '$service' is not ready. State: $state"
            $failed = $true
        }
    }

    if ($failed) {
        throw 'One or more services are not ready.'
    }
}

function Wait-ForHttp {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri
    )

    $lastStatus = 'unavailable'
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 5
            $lastStatus = [string]$response.StatusCode
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                Write-Log "$Name endpoint is ready: $Uri"
                return
            }
        }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $lastStatus = [string][int]$_.Exception.Response.StatusCode
            }
        }
        Start-Sleep -Seconds 2
    }

    throw "$Name endpoint did not become ready: $Uri (last HTTP status: $lastStatus)"
}

function Test-Endpoints {
    $nginxPort = Read-EnvValue -Name 'NGINX_HTTP_PORT' -Fallback '9000'
    Wait-ForHttp -Name 'Jenkins' -Uri "http://127.0.0.1:$nginxPort/login"

    if ($WithObservability) {
        $prometheusPort = Read-EnvValue -Name 'PROMETHEUS_PORT' -Fallback '9090'
        $grafanaPort = Read-EnvValue -Name 'GRAFANA_PORT' -Fallback '3030'
        Wait-ForHttp -Name 'Prometheus' -Uri "http://127.0.0.1:$prometheusPort/-/ready"
        Wait-ForHttp -Name 'Grafana' -Uri "http://127.0.0.1:$grafanaPort/api/health"
    }
}

function Show-Summary {
    $nginxPort = Read-EnvValue -Name 'NGINX_HTTP_PORT' -Fallback '9000'
    $jenkinsPort = Read-EnvValue -Name 'JENKINS_HTTP_PORT' -Fallback '49000'

    Write-Host ''
    Write-Host 'Compose Stack is ready.'
    Write-Host "  Jenkins through Nginx: http://localhost:$nginxPort"
    Write-Host "  Jenkins direct:        http://localhost:$jenkinsPort"

    if ($WithObservability) {
        $prometheusPort = Read-EnvValue -Name 'PROMETHEUS_PORT' -Fallback '9090'
        $grafanaPort = Read-EnvValue -Name 'GRAFANA_PORT' -Fallback '3030'
        Write-Host "  Prometheus:            http://localhost:$prometheusPort"
        Write-Host "  Grafana:               http://localhost:$grafanaPort"
        Write-Host "  Grafana credentials:   configured in $EnvFile"
    }

    $passwordArguments = @('compose', '--env-file', $EnvFile) + $script:ComposeFiles + @(
        'exec', '-T', 'jenkins', 'cat', '/var/jenkins_home/secrets/initialAdminPassword'
    )
    $adminPassword = & docker @passwordArguments 2>$null
    if ($LASTEXITCODE -eq 0 -and $adminPassword) {
        Write-Host "  Jenkins initial password: $($adminPassword | Select-Object -First 1)"
    }
    else {
        Write-Host '  Jenkins initial password: already consumed or unavailable'
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'setup.ps1 supports Windows only. Use setup.sh on Ubuntu.'
}

Set-Location $ScriptRoot
Ensure-Docker

if ($Check) {
    if (-not (Test-Path $EnvFile)) {
        throw 'Missing .env. Run setup.ps1 first.'
    }
    Validate-Configuration
    Test-Services
    Test-Endpoints
    Show-Summary
    exit 0
}

Ensure-Environment
Prepare-HostHome
Validate-Configuration

if ($Update) {
    Write-Log 'Pulling current service images.'
    Invoke-Compose -Arguments @('pull', '--ignore-buildable')
    Write-Log 'Rebuilding the Jenkins image with current base packages.'
    Invoke-Compose -Arguments @('build', '--pull', 'jenkins')
}

Write-Log "Starting the $StackMode stack."
Invoke-Compose -Arguments @('up', '--detach', '--build')
Wait-ForServices
Test-Endpoints
Show-Summary
