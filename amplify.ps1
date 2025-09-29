#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Amplifier Container Wrapper Script for PowerShell
.DESCRIPTION
    Runs Amplifier in a container using Docker or Podman for any target project directory.
    Automatically detects and uses available container runtime (prefers Docker if both installed).
    Can be run from any location including your project directory.
.PARAMETER ProjectPath
    Path to the target project directory (defaults to current directory if not specified)
.PARAMETER DataDir
    Optional path to Amplifier data directory (defaults to ./amplifier-data)
.PARAMETER AmplifierDir
    Optional path to Amplifier installation directory containing Dockerfile
.PARAMETER Runtime
    Force specific container runtime ('docker' or 'podman'). Auto-detects if not specified.
.EXAMPLE
    # Run from your project directory (uses current dir as project)
    amplify.ps1
.EXAMPLE
    # Specify a different project
    amplify.ps1 "C:\MyProject"
.EXAMPLE
    # With custom data directory
    amplify.ps1 "C:\MyProject" "C:\amplifier-data"
.EXAMPLE
    # Run from anywhere, specify Amplifier installation
    amplify.ps1 -AmplifierDir "C:\tools\amplifier"
.EXAMPLE
    # Force use of Podman instead of Docker
    amplify.ps1 -Runtime podman
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $false)]
    [string]$DataDir,

    [Parameter(Mandatory = $false)]
    [string]$AmplifierDir,

    [Parameter(Mandatory = $false)]
    [ValidateSet('docker', 'podman', '')]
    [string]$Runtime = ''
)


# Function to write colored output
function Write-Status {
    param([string]$Message)
    Write-Host "[Amplifier] $Message" -ForegroundColor Blue
}


function Write-Success {
    param([string]$Message)
    Write-Host "[Amplifier] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[Amplifier] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[Amplifier] $Message" -ForegroundColor Red
}

# If ProjectPath not provided, use current directory
if (-not $ProjectPath) {
    $ProjectPath = Get-Location
    Write-Status "No project path provided, using current directory: $ProjectPath"
}

# Detect container runtime
$ContainerCmd = ""
$RuntimeName = ""

if ($Runtime) {
    # User specified runtime
    $ContainerCmd = $Runtime
    $RuntimeName = $Runtime
    Write-Status "Using user-specified runtime: $RuntimeName"
}
else {
    # Auto-detect: prefer Docker if both are installed
    try {
        $dockerVersion = docker --version 2>$null
        if ($dockerVersion) {
            $ContainerCmd = "docker"
            $RuntimeName = "Docker"
            Write-Status "Docker detected: $dockerVersion"
        }
    }
    catch {
        # Docker not found, continue to check for Podman
    }

    if (-not $ContainerCmd) {
        try {
            $podmanVersion = podman --version 2>$null
            if ($podmanVersion) {
                $ContainerCmd = "podman"
                $RuntimeName = "Podman"
                Write-Status "Podman detected: $podmanVersion"
            }
        }
        catch {
            # Podman not found
        }
    }
}

# Validate container runtime is available
if (-not $ContainerCmd) {
    Write-Error "No container runtime found!"
    Write-Error ""
    Write-Error "Please install one of the following:"
    Write-Error "  1. Docker Desktop: https://docker.com/get-started"
    Write-Error "  2. Podman: https://podman.io/getting-started/installation"
    Write-Error ""
    Write-Error "Or specify runtime explicitly with -Runtime parameter"
    exit 1
}

# Check if runtime is accessible
try {
    $versionOutput = & $ContainerCmd --version 2>$null
    if (-not $versionOutput) {
        throw "Runtime not accessible"
    }
}
catch {
    Write-Error "$RuntimeName is not accessible or not in PATH."
    Write-Error "Ensure $RuntimeName is properly installed and available in PATH."
    exit 1
}

# Check if runtime is running (Docker needs daemon, Podman doesn't always)
try {
    & $ContainerCmd info 2>$null | Out-Null
}
catch {
    if ($ContainerCmd -eq "docker") {
        Write-Error "Docker is not running. Please start Docker Desktop first."
        exit 1
    }
    elseif ($ContainerCmd -eq "podman") {
        # Podman doesn't require a daemon, but check if it can run containers
        try {
            & $ContainerCmd version 2>$null | Out-Null
        }
        catch {
            Write-Error "Podman is not working properly. Please check your Podman installation."
            exit 1
        }
    }
}

Write-Success "✓ Using $RuntimeName as container runtime"

# Validate and resolve paths
if (-not (Test-Path $ProjectPath)) {
    Write-Error "Target project directory does not exist: $ProjectPath"
    exit 1
}

$TargetProject = Resolve-Path $ProjectPath
if (-not $DataDir) {
    $DataDir = Join-Path (Get-Location) "amplifier-data"
}

# Create data directory if it doesn't exist
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# Resolve data directory path
$ResolvedDataDir = Resolve-Path $DataDir

Write-Status "Target Project: $TargetProject"
Write-Status "Data Directory: $ResolvedDataDir"

# Build container image if it doesn't exist
$ImageName = "amplifier:latest"
try {
    & $ContainerCmd image inspect $ImageName 2>$null | Out-Null
    Write-Status "Using existing container image: $ImageName"
}
catch {
    Write-Status "Building Amplifier container image..."

    # Determine where to find the Dockerfile
    if ($AmplifierDir) {
        # User specified Amplifier directory
        $DockerfilePath = $AmplifierDir
    }
    else {
        # Try to find Dockerfile in script's directory
        $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $DockerfilePath = $ScriptDir

        # If Dockerfile not found in script dir, check if we're in Amplifier repo
        if (-not (Test-Path (Join-Path $DockerfilePath "Dockerfile"))) {
            if (Test-Path "./Dockerfile") {
                $DockerfilePath = Get-Location
                Write-Status "Found Dockerfile in current directory"
            }
            else {
                Write-Error "Cannot find Dockerfile. Please either:"
                Write-Error "  1. Run this script from the Amplifier directory"
                Write-Error "  2. Provide -AmplifierDir parameter pointing to Amplifier installation"
                Write-Error "  3. Ensure container image 'amplifier:latest' is already built"
                exit 1
            }
        }
    }

    Write-Status "Building from: $DockerfilePath"
    & $ContainerCmd build -t $ImageName $DockerfilePath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build container image"
        exit 1
    }
    Write-Success "Container image built successfully"
}

# Prepare environment variables for Claude Code configuration
$EnvArgs = @()

# Critical API keys that Claude Code needs
$ApiKeys = @(
    "ANTHROPIC_API_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_DEFAULT_REGION",
    "AWS_REGION",
    "CLAUDE_CODE_USE_BEDROCK"
)

# Load settings from local file if it exists
$SettingsValues = @{}
$SettingsFile = Join-Path (Get-Location) ".claude\settings.local.json"

if (Test-Path $SettingsFile) {
    Write-Status "Found local settings file: $SettingsFile"
    try {
        $SettingsContent = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($SettingsContent.env) {
            foreach ($Property in $SettingsContent.env.PSObject.Properties) {
                $SettingsValues[$Property.Name] = $Property.Value
                Write-Status "  Loaded $($Property.Name) from settings file"
            }
        }
    } catch {
        Write-Warning "Failed to parse settings file: $_"
    }
}

$HasAnthropicKey = $false
$HasAwsKeys = $false

foreach ($Key in $ApiKeys) {
    # Environment variable takes precedence over settings file
    $Value = [System.Environment]::GetEnvironmentVariable($Key, [System.EnvironmentVariableTarget]::Process)

    if (-not $Value -and $SettingsValues.ContainsKey($Key)) {
        # Use value from settings file if no environment variable
        $Value = $SettingsValues[$Key]
        Write-Status "✓ Using $Key from settings file"
    }

    if ($Value -or ($Value -eq "" -and $Key -eq "CLAUDE_CODE_USE_BEDROCK")) {
        # Include value (even if empty for CLAUDE_CODE_USE_BEDROCK flag)
        $EnvArgs += "-e"
        $EnvArgs += "$Key=$Value"

        if ([System.Environment]::GetEnvironmentVariable($Key, [System.EnvironmentVariableTarget]::Process)) {
            Write-Status "✓ Forwarding $Key from environment"
        }

        if ($Key -eq "ANTHROPIC_API_KEY") { $HasAnthropicKey = $true }
        if ($Key -eq "AWS_ACCESS_KEY_ID") { $HasAwsKeys = $true }
    }
}

# Validate API key configuration
if (-not $HasAnthropicKey -and -not $HasAwsKeys) {
    Write-Error "❌ No valid API configuration found!"
    Write-Error ""
    Write-Error "Claude Code requires one of the following:"
    Write-Error "  Option 1: Set environment variables:"
    Write-Error "    - ANTHROPIC_API_KEY"
    Write-Error "    - OR AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY"
    Write-Error ""
    Write-Error "  Option 2: Create .claude/settings.local.json with:"
    Write-Error '    {
      "env": {
        "ANTHROPIC_API_KEY": "your-key-here"
      }
    }'
    Write-Error ""
    Write-Error "  Note: Environment variables take precedence over settings file."
    exit 1
}

if ($HasAnthropicKey) {
    Write-Success "🔑 Anthropic API key detected - will use direct API"
}
elseif ($HasAwsKeys) {
    Write-Success "🔑 AWS credentials detected - will use Bedrock"
}

# Function to convert paths for container mounting based on environment
function ConvertTo-ContainerPath {
    param([string]$LocalPath)

    # Simple environment detection using built-in PowerShell variables
    if ($env:WSL_DISTRO_NAME) {
        # Running in WSL - convert Windows paths to WSL mount format
        # C:\Users\... becomes /mnt/c/Users/...
        $ContainerPath = $LocalPath -replace '\\', '/' -replace '^([A-Za-z]):', { '/mnt/' + $_.Groups[1].Value.ToLower() }
        Write-Status "WSL environment: $LocalPath -> $ContainerPath"
        return $ContainerPath
    }
    elseif ($IsWindows -or $env:OS -eq "Windows_NT") {
        # Native Windows - Docker/Podman Desktop handles Windows paths directly
        Write-Status "Windows environment: Using native path $LocalPath"
        return $LocalPath
    }
    else {
        # Unix/Linux - use paths as-is
        Write-Status "Unix environment: Using path $LocalPath"
        return $LocalPath
    }
}

# Convert paths to container-compatible format
$ContainerProjectPath = ConvertTo-ContainerPath -LocalPath $TargetProject.Path
$ContainerDataPath = ConvertTo-ContainerPath -LocalPath $ResolvedDataDir.Path

# Simple validation: test if container runtime can mount the project directory
Write-Status "Testing container mount accessibility..."
try {
    $TestOutput = & $ContainerCmd run --rm -v "${ContainerProjectPath}:/test" alpine:latest test -d /test 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$RuntimeName may not be able to access project directory: $ContainerProjectPath"
        Write-Warning "If container fails to start:"
        if ($ContainerCmd -eq "docker") {
            Write-Warning "  - For Docker Desktop: Enable file sharing for this drive in Settings"
        }
        elseif ($ContainerCmd -eq "podman") {
            Write-Warning "  - For Podman: Check that the path is accessible to Podman"
            Write-Warning "  - You may need to use 'podman machine' commands to configure file sharing"
        }
        Write-Warning "  - For WSL: Ensure path is accessible from within WSL"
        Write-Warning "  - Check path exists and has proper permissions"
    }
    else {
        Write-Success "Container mount test successful"
    }
}
catch {
    Write-Warning "Could not test container mount accessibility: $_"
    Write-Warning "Container will attempt to start anyway"
}

# Run the container with Claude Code pre-configured
Write-Status "🚀 Starting Amplifier container using $RuntimeName..."
Write-Status "📁 Project: $ContainerProjectPath → /workspace"
Write-Status "💾 Data: $ContainerDataPath → /app/amplifier-data"

if ($HasAnthropicKey) {
    Write-Status "🔗 API: Anthropic Direct API"
}
elseif ($HasAwsKeys) {
    Write-Status "🔗 API: AWS Bedrock"
}

Write-Warning "⚠️  IMPORTANT: When Claude starts, send this first message:"
Write-Host "===========================================" -ForegroundColor Yellow
Write-Host "I'm working in /workspace which contains my project files." -ForegroundColor White
Write-Host "Please cd to /workspace and work there." -ForegroundColor White
Write-Host "Do NOT update any issues or PRs in the Amplifier repo." -ForegroundColor White
Write-Host "===========================================" -ForegroundColor Yellow
Write-Host ""
Write-Status "Press Ctrl+C to exit when done"

$ContainerName = "amplifier-$(Split-Path -Leaf $TargetProject)-$PID"

# Container run arguments with complete environment configuration
$ContainerArgs = @("run", "-it", "--rm") +
$EnvArgs +
@(
    # Essential environment variables for Amplifier operation
    "-e", "TARGET_DIR=/workspace"                    # Target project directory in container
    "-e", "AMPLIFIER_DATA_DIR=/app/amplifier-data"   # Amplifier data persistence
    # Volume mounts: Host → Container
    "-v", "$($ContainerProjectPath):/workspace"         # User project files
    "-v", "$($ContainerDataPath):/app/amplifier-data"   # Amplifier data directory
    # Container identification
    "--name", $ContainerName
    $ImageName
)

Write-Status "Executing: $ContainerCmd run with $(($ContainerArgs | Where-Object { $_ -eq '-e' }).Count) environment variables"

try {
    & $ContainerCmd @ContainerArgs
    Write-Success "✅ Amplifier session completed successfully"
}
catch {
    Write-Error "❌ Failed to run Amplifier container: $_"
    Write-Error "Check that $RuntimeName is running and the image exists"
    exit 1
}