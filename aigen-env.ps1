param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Push', 'Pull')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = 'D:\DOT Indonesia'
$remoteHost = 'biznet'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$repositories = @(
    [pscustomobject]@{
        Name = 'backend'
        LocalEnvPath = Join-Path $workspaceRoot 'backend\.env'
        RemoteEnvPath = '/home/elginbrian/dot-backend/.env'
    },
    [pscustomobject]@{
        Name = 'ISourcing'
        LocalEnvPath = Join-Path $workspaceRoot 'ISourcing\.env'
        RemoteEnvPath = '/home/elginbrian/ISourcing/.env'
    }
)

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $normalizedCommand = ($Command -replace "`r`n", "`n") -replace "`r", "`n"

    & ssh $remoteHost $normalizedCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Remote command failed: $Command"
    }
}

function Test-RemoteFileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteFile
    )

    & ssh $remoteHost "test -f $RemoteFile"
    return $LASTEXITCODE -eq 0
}

function Push-EnvironmentFiles {
    foreach ($repository in $repositories) {
        Write-Host "==> $($repository.Name)"

        if (-not (Test-Path $repository.LocalEnvPath)) {
            throw "[$($repository.Name)] Local env file not found: $($repository.LocalEnvPath)"
        }

        if (Test-RemoteFileExists -RemoteFile $repository.RemoteEnvPath) {
            Invoke-RemoteCommand -Command "cp $($repository.RemoteEnvPath) $($repository.RemoteEnvPath).bak-$timestamp"
            Write-Host "[$($repository.Name)] Backed up remote env to $($repository.RemoteEnvPath).bak-$timestamp"
        }

        & scp $repository.LocalEnvPath ("{0}:{1}" -f $remoteHost, $repository.RemoteEnvPath)
        if ($LASTEXITCODE -ne 0) {
            throw "[$($repository.Name)] Failed to push env file to VPS"
        }

        Write-Host "[$($repository.Name)] Pushed local env to VPS"
    }

    Write-Host 'Env push completed for backend and ISourcing.'
}

function Pull-EnvironmentFiles {
    foreach ($repository in $repositories) {
        Write-Host "==> $($repository.Name)"

        if (-not (Test-RemoteFileExists -RemoteFile $repository.RemoteEnvPath)) {
            throw "[$($repository.Name)] Remote env file not found: $($repository.RemoteEnvPath)"
        }

        if (Test-Path $repository.LocalEnvPath) {
            Copy-Item -Path $repository.LocalEnvPath -Destination "$($repository.LocalEnvPath).bak-$timestamp" -Force
            Write-Host "[$($repository.Name)] Backed up local env to $($repository.LocalEnvPath).bak-$timestamp"
        }

        & scp ("{0}:{1}" -f $remoteHost, $repository.RemoteEnvPath) $repository.LocalEnvPath
        if ($LASTEXITCODE -ne 0) {
            throw "[$($repository.Name)] Failed to pull env file from VPS"
        }

        Write-Host "[$($repository.Name)] Pulled remote env to local"
    }

    Write-Host 'Env pull completed for backend and ISourcing.'
}

switch ($Action) {
    'Push' {
        Push-EnvironmentFiles
    }
    'Pull' {
        Pull-EnvironmentFiles
    }
}