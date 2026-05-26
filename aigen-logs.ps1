param(
    [Parameter(Position = 0)]
    [ValidateSet('be', 'fe', 'isc', 'db', 'gw', 'ipr', 'backend', 'frontend', 'isourcing', 'database', 'mysql', 'import-pr-gateway', 'aigen-import-pr')]
    [string]$Target = 'be'
)

$ErrorActionPreference = 'Stop'
$remoteHost = 'biznet'

$containerName = ''
switch ($Target) {
    { $_ -in 'be', 'backend' } {
        $containerName = 'dot-backend-api'
    }
    { $_ -in 'fe', 'frontend' } {
        $containerName = 'aigen-frontend'
    }
    { $_ -in 'isc', 'isourcing' } {
        $containerName = 'isourcing-app'
    }
    { $_ -in 'db', 'database', 'mysql' } {
        $containerName = 'aigen-mysql'
    }
    { $_ -in 'gw', 'import-pr-gateway' } {
        $containerName = 'import-pr-gateway'
    }
    { $_ -in 'ipr', 'aigen-import-pr' } {
        $containerName = 'aigen-import-pr'
    }
}

Write-Host "==> Attaching to logs for $containerName on $remoteHost..."
Write-Host "Press Ctrl+C to stop trailing logs and return to this terminal." -ForegroundColor Cyan

# We use ssh with -t to allocate a pseudo-terminal for Ctrl+C to work cleanly
ssh -t $remoteHost "docker logs -f --tail 100 $containerName"

