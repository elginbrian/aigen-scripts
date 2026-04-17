param(
    [Parameter(Position = 0)]
    [ValidateSet('be', 'fe', 'isc', 'db', 'backend', 'frontend', 'isourcing', 'database', 'mysql')]
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
}

Write-Host "==> Attaching to logs for $containerName on $remoteHost..."
Write-Host "Press Ctrl+C to stop trailing logs and return to this terminal." -ForegroundColor Cyan

# We use ssh with -t to allocate a pseudo-terminal for Ctrl+C to work cleanly
ssh -t $remoteHost "docker logs -f --tail 100 $containerName"
