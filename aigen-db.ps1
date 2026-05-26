param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('migrate', 'seed', 'fresh')]
    [string]$Action,

    [Parameter(Position = 1)]
    [ValidateSet('be', 'backend', 'isc', 'isourcing', 'all')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'
$remoteHost = 'biznet'

# Map friendly target names
if ($Target -eq 'be') { $Target = 'backend' }
if ($Target -eq 'isc') { $Target = 'isourcing' }

Write-Host "Starting Database synchronization for task: $Action on target: $Target" -ForegroundColor Cyan

$backendScript = ""
$isourcingScript = ""

switch ($Action) {
    'migrate' {
        $backendScript = "docker exec dot-backend-api bash -c 'npm run migrate up -- --db=aigen && npm run migrate up -- --db=task_board && npm run migrate up -- --db=prpo'"
        $isourcingScript = "docker exec isourcing-app php artisan migrate --force"
    }
    'seed' {
        $backendScript = "docker exec dot-backend-api bash -c 'npm run seed -- --db=aigen && if [ -d ""/app/seeders/task_board"" ]; then npm run seed -- --db=task_board; fi && if [ -d ""/app/seeders/prpo"" ]; then npm run seed -- --db=prpo; fi'"
        $isourcingScript = "docker exec isourcing-app php artisan db:seed --force"
    }
    'fresh' {
        if ($Target -ne 'all') {
            Write-Host "Warning: 'fresh' destroys all shared raw databases entirely. Forcing target to 'all' to ensure ISourcing base tables are safely rebuilt before Backend runs." -ForegroundColor Yellow
            $Target = 'all'
        }
        
        # Drops ALL tables across shared databases and re-runs all migrations + seeds for both services
        # We pipe the SQL securely from the VPS host down into the docker container to avoid SSH quote-stripping issues
        $dbResetScript = "echo 'DROP DATABASE IF EXISTS aigen_db; CREATE DATABASE aigen_db; DROP DATABASE IF EXISTS task_board; CREATE DATABASE task_board; DROP DATABASE IF EXISTS prpo; CREATE DATABASE prpo;' | docker exec -i aigen-mysql mysql -uroot -pyour_password_here"
        
        # Execute the DB drop first
        Write-Host "Wiping raw databases (aigen_db, task_board, prpo)..." -ForegroundColor Yellow
        ssh -t $remoteHost $dbResetScript
        
        $backendScript = "docker exec dot-backend-api bash -c 'npm run migrate up -- --db=aigen && npm run seed -- --db=aigen && npm run migrate up -- --db=task_board && if [ -d ""/app/seeders/task_board"" ]; then npm run seed -- --db=task_board; fi && npm run migrate up -- --db=prpo && if [ -d ""/app/seeders/prpo"" ]; then npm run seed -- --db=prpo; fi'"
        $isourcingScript = "docker exec isourcing-app php artisan migrate --seed --force"
    }
}

# IMPORTANT: ISourcing (Laravel) provides the core base schemas (like users table), while the Backend script often adds secondary fields to them later. So ISourcing must always be migrated FIRST when dealing with shared databases.
if ($Target -eq 'isourcing' -or $Target -eq 'all') {
    Write-Host "Running $Action on ISourcing (isourcing-app)..." -ForegroundColor Yellow
    ssh -t $remoteHost $isourcingScript
    if ($LASTEXITCODE -eq 0) {
        Write-Host "ISourcing DB $Action completed successfully.`n" -ForegroundColor Green
    } else {
        Write-Host "ISourcing DB $Action failed.`n" -ForegroundColor Red
        if ($Action -eq 'fresh') { exit 1 }
    }
}

if ($Target -eq 'backend' -or $Target -eq 'all') {
    Write-Host "Running $Action on Backend (dot-backend-api)..." -ForegroundColor Yellow
    ssh -t $remoteHost $backendScript
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Backend DB $Action completed successfully.`n" -ForegroundColor Green
    } else {
        Write-Host "Backend DB $Action failed.`n" -ForegroundColor Red
    }
}

Write-Host "Database sync operations finished." -ForegroundColor Cyan
