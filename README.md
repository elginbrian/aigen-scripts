# Aigen Scripts Guide

This document explains the PowerShell automation used from your local Windows machine to operate and sync the VPS deployment for both services:

- `backend` (Node.js API)
- `ISourcing` (Laravel app)

## Script Files

- `aigen-sync.ps1`: sync changed working-tree files (including uncommitted changes) to VPS, then redeploy both services.
- `aigen-vps.ps1`: perform VPS service lifecycle operations (`Up`, `Down`, `Rebuild`).
- `aigen-env.ps1`: synchronize `.env` files between local and VPS (`Push`, `Pull`).
- `aigen-logs.ps1`: tail and stream remote runtime logs locally directly to your terminal.

## PowerShell Command Entry

Commands are exposed through the `aigen` function in your PowerShell profile:

- Profile path: `C:\Users\LENOVO\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`

Run from PowerShell:

```powershell
aigen sync
aigen sync be
aigen sync fe
aigen sync isc
aigen up
aigen down
aigen rebuild
aigen env push
aigen env pull
aigen logs
aigen logs be
aigen logs fe
aigen logs isc
aigen logs db
```

## Command Behavior

### 1) `aigen sync`

Purpose:

- Make VPS code match your local working tree for both repos.
- Works even if you have not committed yet.

Behavior:

- Detects changed/untracked/deleted files in local repo.
- Uploads changed files to VPS via SCP.
- Removes deleted files from VPS.
- Deploys each repo using its strategy:
  - backend: run remote script `bash ./deploy-run-3001.sh`
  - ISourcing: no remote redeploy command by default (sync only)
  - frontend: build locally with `pnpm run build`, upload `dist/`, then restart `aigen-frontend` container using mounted static assets and Caddy config (no Docker build on VPS)

Targeted modes:

- `aigen sync be` or `aigen sync backend`: sync backend only.
- `aigen sync fe` or `aigen sync frontend`: sync frontend only.
- `aigen sync isc` or `aigen sync isourcing`: sync ISourcing only.

### 2) `aigen up`

Purpose:

- Start backend and ISourcing services on VPS.

Behavior:

- Backend:
  - Start `aigen-mysql` if container exists and is stopped.
  - Start `dot-backend-api` if container exists and is stopped.
  - If required container does not exist, fallback to backend deploy script.
- ISourcing:
  - Start `isourcing-app` if container exists and is stopped.
  - If container does not exist, fallback to iSourcing redeploy script.

### 3) `aigen down`

Purpose:

- Stop backend and ISourcing services on VPS.

Behavior:

- Stops backend containers:
  - `dot-backend-api`
  - `aigen-mysql`
- Stops iSourcing container:
  - `isourcing-app`

### 4) `aigen rebuild`

Purpose:

- Force rebuild/redeploy of both services on VPS.

Behavior:

- Runs remote scripts:
  - backend: `bash ./deploy-run-3001.sh`
  - ISourcing: `bash ./redeploy.sh`

### 5) `aigen env push`

Purpose:

- Make VPS `.env` match your local `.env` for both repos.

Behavior:

- backend:
  - Local: `D:\DOT Indonesia\backend\.env`
  - Remote: `/home/elginbrian/dot-backend/.env`
- ISourcing:
  - Local: `D:\DOT Indonesia\ISourcing\.env`
  - Remote: `/home/elginbrian/ISourcing/.env`
- Creates remote backup before overwrite:
  - `.env.bak-YYYYMMDD-HHMMSS`

### 6) `aigen env pull`

Purpose:

- Make local `.env` match VPS `.env` for both repos.

Behavior:

- Pulls remote `.env` into local `.env` for backend and ISourcing.
- Creates local backup before overwrite:
  - `.env.bak-YYYYMMDD-HHMMSS`

### 7) `aigen logs`

Purpose:

- Tail and stream remote docker container logs right in your local terminal.
- Stop gracefully and return to your terminal anytime by pressing Ctrl+C.

Behavior:

- Targeted modes:
  - `aigen logs be` or `aigen logs backend`: Ttails `dot-backend-api`
  - `aigen logs fe` or `aigen logs frontend`: Tails `aigen-frontend`
  - `aigen logs isc` or `aigen logs isourcing`: Tails `isourcing-app`
  - `aigen logs db` or `aigen logs mysql`: Tails `aigen-mysql`

## Important Notes

- These commands target host alias `biznet` over SSH/SCP.
- Ensure your SSH config and key access for `biznet` are working.
- `aigen env push` and `aigen env pull` overwrite `.env` values after creating backups.
- VPS deploy scripts can emit non-fatal warnings (legacy Laravel behavior); check for final success line to confirm completion.

## Quick Verification

```powershell
# Show command help text
aigen

# Start services
aigen up

# Stop services
aigen down

# Rebuild both services
aigen rebuild

# Sync local code changes then redeploy
aigen sync

# Sync environment files
aigen env pull
aigen env push
```

## Troubleshooting

### `aigen` command not found

- Reload your profile:

```powershell
. 'C:\Users\LENOVO\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
```

### SSH/SCP fails

- Test SSH first:

```powershell
ssh biznet
```

### Service operation fails on VPS

- Check whether containers exist:

```bash
docker ps -a --format '{{.Names}}'
```

- Check deploy scripts directly on VPS:
  - `/home/elginbrian/dot-backend/deploy-run-3001.sh`
  - `/home/elginbrian/ISourcing/redeploy.sh`
