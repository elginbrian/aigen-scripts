param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'be', 'fe', 'isc', 'gw', 'ipr', 'autotest', 'backend', 'frontend', 'isourcing', 'import-pr-gateway', 'aigen-import-pr')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = 'D:\DOT Indonesia'
$remoteHost = 'biznet'

$repositories = @(
    [pscustomobject]@{
        Name = 'backend'
        LocalPath = Join-Path $workspaceRoot 'backend'
        RemotePath = '/home/elginbrian/dot-backend'
        DeployCommand = 'bash ./deploy-run-3001.sh'
    },
    [pscustomobject]@{
        Name = 'ISourcing'
        LocalPath = Join-Path $workspaceRoot 'ISourcing'
        RemotePath = '/home/elginbrian/ISourcing'
    },
    [pscustomobject]@{
        Name = 'frontend'
        LocalPath = Join-Path $workspaceRoot 'frontend'
        RemotePath = '/home/elginbrian/frontend'
        DeployCommand = 'bash ./redeploy.sh'
    },
    [pscustomobject]@{
        Name = 'autotest'
        LocalPath = Join-Path $workspaceRoot 'sinarmas-aigen-api-automation-test'
        RemotePath = '/home/elginbrian/sinarmas-aigen-api-automation-test'
        GitRemoteUrl = 'git@gitlab.dot.co.id:sinarmas/aigen/sinarmas-aigen-api-automation-test.git'
        DeployCommand = 'source ~/.nvm/nvm.sh && npm install'
    },
    [pscustomobject]@{
        Name = 'import-pr-gateway'
        LocalPath = Join-Path $workspaceRoot 'import-pr-gateway'
        RemotePath = '/home/elginbrian/import-pr-gateway'
        GitRemoteUrl = 'git@gitlab.dot.co.id:sinarmas/aigen/import-pr-gateway.git'
        DeployCommand = 'source ~/.nvm/nvm.sh && npm install --omit=dev && docker stop import-pr-gateway 2>/dev/null || true && docker rm import-pr-gateway 2>/dev/null || true && docker build -t import-pr-gateway . && touch .env && docker run -d --name import-pr-gateway --env-file .env --network ${DOCKER_NETWORK_NAME:-dot-backend_aigen-network} -p 4000:3000 --restart unless-stopped import-pr-gateway'
    },
    [pscustomobject]@{
        Name = 'aigen-import-pr'
        LocalPath = Join-Path $workspaceRoot 'aigen-import-pr'
        RemotePath = '/home/elginbrian/aigen-import-pr'
        GitRemoteUrl = 'git@gitlab.dot.co.id:sinarmas/aigen/aigen-import-pr.git'
        DeployCommand = 'source ~/.nvm/nvm.sh && npm install --omit=dev && docker stop aigen-import-pr 2>/dev/null || true && docker rm aigen-import-pr 2>/dev/null || true && docker build -t aigen-import-pr . && touch .env && docker run -d --name aigen-import-pr --env-file .env --network ${DOCKER_NETWORK_NAME:-dot-backend_aigen-network} --restart unless-stopped aigen-import-pr'
    }
)

function Get-GitChangedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $modified = & git -C $RepositoryPath diff --name-only --diff-filter=ACMR HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read modified files for $RepositoryPath"
    }

    $deleted = & git -C $RepositoryPath diff --name-only --diff-filter=D HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read deleted files for $RepositoryPath"
    }

    $untracked = & git -C $RepositoryPath ls-files --others --exclude-standard
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read untracked files for $RepositoryPath"
    }

    return [pscustomobject]@{
        Modified  = @($modified | Where-Object { $_ })
        Deleted   = @($deleted | Where-Object { $_ })
        Untracked = @($untracked | Where-Object { $_ })
    }
}

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

function Get-SelectedRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Selection
    )

    switch ($Selection.ToLowerInvariant()) {
        'all' { return @($repositories) }
        'autotest' { return @($repositories | Where-Object { $_.Name -eq 'autotest' }) }
        'be' { return @($repositories | Where-Object { $_.Name -eq 'backend' }) }
        'backend' { return @($repositories | Where-Object { $_.Name -eq 'backend' }) }
        'fe' { return @($repositories | Where-Object { $_.Name -eq 'frontend' }) }
        'frontend' { return @($repositories | Where-Object { $_.Name -eq 'frontend' }) }
        'isc' { return @($repositories | Where-Object { $_.Name -eq 'ISourcing' }) }
        'isourcing' { return @($repositories | Where-Object { $_.Name -eq 'ISourcing' }) }
        'gw' { return @($repositories | Where-Object { $_.Name -eq 'import-pr-gateway' }) }
        'import-pr-gateway' { return @($repositories | Where-Object { $_.Name -eq 'import-pr-gateway' }) }
        'ipr' { return @($repositories | Where-Object { $_.Name -eq 'aigen-import-pr' }) }
        'aigen-import-pr' { return @($repositories | Where-Object { $_.Name -eq 'aigen-import-pr' }) }
        default { throw "Unsupported sync target: $Selection" }
    }
}


function Get-EnvValueFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    $matchedLine = Get-Content $FilePath | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=\s*" } | Select-Object -First 1
    if (-not $matchedLine) {
        return $null
    }

    $value = (($matchedLine -split '=', 2)[1]).Trim()
    if (-not $value) {
        return $null
    }

    return $value
}

function Get-FrontendApiUrl {
    $explicitApiUrl = $env:AIGEN_FE_API_URL
    if ($null -ne $explicitApiUrl) {
        $explicitApiUrl = $explicitApiUrl.Trim()
        if ($explicitApiUrl) {
            return $explicitApiUrl
        }
    }

    $frontendEnvProduction = Join-Path $workspaceRoot 'frontend\.env.production'
    $frontendEnv = Join-Path $workspaceRoot 'frontend\.env'

    $apiFromEnvProduction = Get-EnvValueFromFile -FilePath $frontendEnvProduction -Key 'VITE_API_URL'
    if ($apiFromEnvProduction) {
        return $apiFromEnvProduction
    }

    $apiFromEnv = Get-EnvValueFromFile -FilePath $frontendEnv -Key 'VITE_API_URL'
    if ($apiFromEnv) {
        return $apiFromEnv
    }

    $backendEnv = Join-Path $workspaceRoot 'backend\.env'
    $backendAppUrl = Get-EnvValueFromFile -FilePath $backendEnv -Key 'APP_URL'
    if (-not $backendAppUrl) {
        throw '[frontend] Could not determine API URL. Set AIGEN_FE_API_URL or VITE_API_URL in frontend/.env(.production).'
    }

    $apiBase = $backendAppUrl.TrimEnd('/')
    if ($apiBase -match '^https?://[^/:]+$') {
        $apiBase = "${apiBase}:3001"
    }

    if (-not $apiBase) {
        throw '[frontend] Determined API URL is empty. Set backend APP_URL or AIGEN_FE_API_URL.'
    }

    return $apiBase
}

function Invoke-LocalFrontendBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$ApiUrl
    )

    Push-Location $LocalPath
    try {
        $normalizedApiUrl = $ApiUrl.TrimEnd('/')
        if ($normalizedApiUrl.EndsWith('/v1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalizedApiUrl = $normalizedApiUrl.Substring(0, $normalizedApiUrl.Length - 3)
            Write-Host "[frontend] Adjusted API URL to backend route base (removed /v1): $normalizedApiUrl"
        }

        $buildEnvOverridePath = Join-Path $LocalPath '.env.production.local'
        Set-Content -Path $buildEnvOverridePath -Value "VITE_API_URL=$normalizedApiUrl" -Encoding ascii

        $nodeModulesPath = Join-Path $LocalPath 'node_modules'
        $eslintPath = Join-Path $nodeModulesPath '.bin\eslint.cmd'

        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            Write-Host '[frontend] Running local build with pnpm...'

            if (-not (Test-Path $eslintPath)) {
                Write-Host '[frontend] Installing frontend dependencies with pnpm...'
                & pnpm install --frozen-lockfile
                if ($LASTEXITCODE -ne 0) {
                    throw '[frontend] Failed to install frontend dependencies with pnpm.'
                }
            }

            & pnpm run build
            if ($LASTEXITCODE -ne 0) {
                throw '[frontend] Local frontend build failed with pnpm.'
            }

            return
        }

        if (Get-Command npx -ErrorAction SilentlyContinue) {
            Write-Host '[frontend] pnpm not found in PATH, trying npx pnpm@10.22.0...'

            if (-not (Test-Path $eslintPath)) {
                Write-Host '[frontend] Installing frontend dependencies with npx pnpm@10.22.0...'
                & npx --yes pnpm@10.22.0 install --frozen-lockfile
                if ($LASTEXITCODE -ne 0) {
                    throw '[frontend] Failed to install frontend dependencies with npx pnpm.'
                }
            }

            & npx --yes pnpm@10.22.0 run build
            if ($LASTEXITCODE -eq 0) {
                return
            }

            Write-Host '[frontend] npx pnpm build failed, trying npm run build...'
        }
        else {
            Write-Host '[frontend] pnpm/npx not found, trying npm run build...'
        }

        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw '[frontend] Could not find pnpm, npx, or npm in PATH. Install Node.js (with npm) or pnpm.'
        }

        if (-not (Test-Path $eslintPath)) {
            Write-Host '[frontend] Installing frontend dependencies with npm...'
            & npm install
            if ($LASTEXITCODE -ne 0) {
                throw '[frontend] Failed to install frontend dependencies with npm.'
            }
        }

        & npm run build
        if ($LASTEXITCODE -ne 0) {
            throw '[frontend] Local frontend build failed with npm.'
        }

        Write-Host "[frontend] Build completed with VITE_API_URL=$normalizedApiUrl"
    }
    finally {
        $buildEnvOverridePath = Join-Path $LocalPath '.env.production.local'
        if (Test-Path $buildEnvOverridePath) {
            Remove-Item -Path $buildEnvOverridePath -Force
        }

        Pop-Location
    }
}

function Invoke-FrontendDeploy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )

    Write-Host '[frontend] Building frontend assets locally...'
    $frontendApiUrl = Get-FrontendApiUrl
    Write-Host "[frontend] Using API URL: $frontendApiUrl"
    Invoke-LocalFrontendBuild -LocalPath $LocalPath -ApiUrl $frontendApiUrl

    $distPath = Join-Path $LocalPath 'dist'
    if (-not (Test-Path $distPath)) {
        throw "[frontend] Build output not found: $distPath"
    }

    $distIndexPath = Join-Path $distPath 'index.html'
    if (-not (Test-Path $distIndexPath)) {
        throw "[frontend] Build output is invalid (missing index.html): $distIndexPath"
    }

    $archivePath = Join-Path $env:TEMP 'aigen-frontend-dist.tar.gz'
    if (Test-Path $archivePath) {
        Remove-Item $archivePath -Force
    }

    & tar -czf $archivePath -C $distPath .
    if ($LASTEXITCODE -ne 0) {
        throw '[frontend] Failed to package dist artifacts.'
    }

    $remoteArchivePath = '/tmp/aigen-frontend-dist.tar.gz'
    & scp $archivePath ("{0}:{1}" -f $remoteHost, $remoteArchivePath)
    if ($LASTEXITCODE -ne 0) {
        throw '[frontend] Failed to upload dist artifacts to VPS.'
    }

    $frontendDeployCommand = @"
set -e
mkdir -p $RemotePath
rm -rf $RemotePath/dist_new
mkdir -p $RemotePath/dist_new
tar -xzf $remoteArchivePath -C $RemotePath/dist_new
rm -f $remoteArchivePath
test -f $RemotePath/dist_new/index.html
if [ -d $RemotePath/dist ]; then
    rm -rf $RemotePath/dist_backup
    mv $RemotePath/dist $RemotePath/dist_backup
fi
mv $RemotePath/dist_new $RemotePath/dist
docker stop aigen-frontend >/dev/null 2>&1 || true
docker rm aigen-frontend >/dev/null 2>&1 || true
docker run -d --name aigen-frontend -p 3000:80 -v $RemotePath/dist:/app:ro -v $RemotePath/deploy/caddy/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine >/dev/null
rm -rf $RemotePath/dist_backup
"@

    Invoke-RemoteCommand -Command $frontendDeployCommand
    Write-Host '[frontend] Frontend static artifacts deployed without VPS image build.'
}

function Sync-RepositoryFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [string]$GitRemoteUrl = '',
        [string]$DeployCommand = ''
    )

    if (-not (Test-Path $LocalPath)) {
        throw "Local path not found: $LocalPath"
    }

    Push-Location $LocalPath
    try {
        $branch = (git branch --show-current).Trim()
        if ($branch) {
            # Check if remote directory exists - if not, clone first
            & ssh $remoteHost "test -d $RemotePath/.git"
            $remoteExists = $LASTEXITCODE -eq 0

            if (-not $remoteExists) {
                if ($GitRemoteUrl) {
                    Write-Host "[$Name] Remote directory not found - cloning from $GitRemoteUrl..."
                    Invoke-RemoteCommand -Command "git clone $GitRemoteUrl $RemotePath"
                    Write-Host "[$Name] Clone complete."
                } else {
                    throw "[$Name] Remote path does not exist and no GitRemoteUrl defined. Cannot initialise VPS repo."
                }
            }

            Write-Host "[$Name] Setting VPS to branch '$branch' and pulling latest changes from origin..."
            Invoke-RemoteCommand -Command "cd $RemotePath && git fetch origin && git stash && git checkout $branch && git pull origin $branch"
        }

        $changes = Get-GitChangedFiles -RepositoryPath $LocalPath
        $allChangedFiles = @($changes.Modified + $changes.Untracked) | Sort-Object -Unique

        if (-not $allChangedFiles -and -not $changes.Deleted) {
            Write-Host "[$Name] No local changes detected. Rebuilding remote deployment anyway."
        } else {
            Write-Host "[$Name] Syncing changed files to VPS..."

            foreach ($relativePath in $allChangedFiles) {
                $windowsRelativePath = $relativePath -replace '/', '\\'
                $localFile = Join-Path $LocalPath $windowsRelativePath
                if (-not (Test-Path $localFile)) {
                    continue
                }

                $remoteRelativePath = $relativePath -replace '\\', '/'
                $remoteFullPath = "$RemotePath/$remoteRelativePath"
                $remoteDirectory = Split-Path $remoteFullPath -Parent

                Invoke-RemoteCommand -Command "mkdir -p $remoteDirectory"
                & scp $localFile ("{0}:{1}" -f $remoteHost, $remoteFullPath)
                if ($LASTEXITCODE -ne 0) {
                    throw "[$Name] Failed to copy $relativePath to VPS"
                }

                Write-Host "[$Name] Copied $relativePath"
            }

            foreach ($relativePath in $changes.Deleted) {
                $remoteRelativePath = $relativePath -replace '\\', '/'
                $remoteFullPath = "$RemotePath/$remoteRelativePath"
                Invoke-RemoteCommand -Command "rm -f $remoteFullPath"
                Write-Host "[$Name] Removed $relativePath from VPS"
            }
        }

        if ($Name -eq 'frontend') {
            Invoke-FrontendDeploy -LocalPath $LocalPath -RemotePath $RemotePath
        }
        elseif ($DeployCommand) {
            Invoke-RemoteCommand -Command "cd $RemotePath && $DeployCommand"
            Write-Host "[$Name] Remote deployment rebuilt successfully."
        }
        else {
            Write-Host "[$Name] No deploy command configured; file sync completed without remote redeploy."
        }
    }
    finally {
        Pop-Location
    }
}

foreach ($repository in (Get-SelectedRepositories -Selection $Target)) {
    Write-Host "==> Syncing $($repository.Name)"
    $gitUrl = if ($repository.GitRemoteUrl) { $repository.GitRemoteUrl } else { '' }
    $deployCmd = if ($repository.DeployCommand) { $repository.DeployCommand } else { '' }

    Sync-RepositoryFiles `
        -Name $repository.Name `
        -LocalPath $repository.LocalPath `
        -RemotePath $repository.RemotePath `
        -GitRemoteUrl $gitUrl `
        -DeployCommand $deployCmd
}

if ($Target -eq 'all') {
    Write-Host 'All repositories synchronized to VPS and redeployed.'
}
else {
    Write-Host "Selected repository synchronized to VPS and redeployed: $Target"
}