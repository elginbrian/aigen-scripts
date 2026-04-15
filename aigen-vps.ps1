param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Up', 'Down', 'Rebuild')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$remoteHost = 'biznet'

$repositories = @(
    [pscustomobject]@{
        Name = 'backend'
        RemotePath = '/home/elginbrian/dot-backend'
        UpCommand = @'
start_if_stopped() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$1"; then
        if [ "$(docker inspect -f '{{.State.Running}}' "$1")" != "true" ]; then
            docker start "$1" >/dev/null
        fi
        return 0
    fi

    return 1
}

start_if_stopped aigen-mysql || bash ./deploy-run-3001.sh
start_if_stopped dot-backend-api || bash ./deploy-run-3001.sh
'@
        DownCommand = @'
docker stop dot-backend-api >/dev/null 2>&1 || true
docker stop aigen-mysql >/dev/null 2>&1 || true
'@
        RebuildCommand = 'bash ./deploy-run-3001.sh'
    },
    [pscustomobject]@{
        Name = 'ISourcing'
        RemotePath = '/home/elginbrian/ISourcing'
        UpCommand = @'
if docker ps -a --format '{{.Names}}' | grep -qx 'isourcing-app'; then
    if [ "$(docker inspect -f '{{.State.Running}}' isourcing-app)" != "true" ]; then
        docker start isourcing-app >/dev/null
    fi
else
    bash ./redeploy.sh
fi
'@
        DownCommand = @'
docker stop isourcing-app >/dev/null 2>&1 || true
'@
        RebuildCommand = 'bash ./redeploy.sh'
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

function Invoke-RepositoryAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$SuccessMessage
    )

    Write-Host "==> $Name"
    Invoke-RemoteCommand -Command "cd $RemotePath && $Command"
    Write-Host "[$Name] $SuccessMessage"
}

switch ($Action) {
    'Up' {
        foreach ($repository in $repositories) {
            Invoke-RepositoryAction -Name $repository.Name -RemotePath $repository.RemotePath -Command $repository.UpCommand -SuccessMessage 'Remote services started successfully.'
        }

        Write-Host 'All repositories are up on the VPS.'
    }
    'Down' {
        foreach ($repository in $repositories) {
            Invoke-RepositoryAction -Name $repository.Name -RemotePath $repository.RemotePath -Command $repository.DownCommand -SuccessMessage 'Remote services stopped successfully.'
        }

        Write-Host 'All repositories are down on the VPS.'
    }
    'Rebuild' {
        foreach ($repository in $repositories) {
            Invoke-RepositoryAction -Name $repository.Name -RemotePath $repository.RemotePath -Command $repository.RebuildCommand -SuccessMessage 'Remote deployment rebuilt successfully.'
        }

        Write-Host 'All repositories were rebuilt on the VPS.'
    }
}