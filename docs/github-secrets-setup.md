# NEPS Digital — GitHub Secrets & Repository Setup Guide

## Overview

Every CI/CD pipeline in the NEPS ecosystem requires secrets to be configured in each
repository's GitHub Settings. **Without these, pipelines will fail at the build and deploy stages.**

---

## Required Secrets Per Repository

Configure these in: **GitHub Repo → Settings → Secrets and variables → Actions → New repository secret**

### All Repositories (`neps-portal`, `neps-backend`, `neps-ml-ai`, `neps-data-platform`)

| Secret Name | Description | How to Get |
|---|---|---|
| `GHCR_PAT` | GitHub Container Registry Personal Access Token | See Section 1 below |
| `DEPLOY_HOST` | IP or hostname of your production server | From your cloud provider |
| `DEPLOY_USER` | SSH username on the production server | e.g. `ubuntu`, `ec2-user` |
| `DEPLOY_KEY` | SSH private key for server access | See Section 2 below |

### `neps-portal` Only

| Secret Name | Description |
|---|---|
| `NEXT_PUBLIC_API_URL` | Public URL of the backend API (e.g. `https://api.nepsdigital.org`) |

---

## Section 1: Creating the GHCR Personal Access Token

1. Go to **GitHub → Profile → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token (classic)**
3. Set expiry: **90 days** (or longer if preferred, rotate regularly)
4. Select these scopes:
   - ✅ `write:packages` — push images to GHCR
   - ✅ `read:packages` — pull images
   - ✅ `delete:packages` — clean up old images (optional but recommended)
5. Copy the generated token — you **cannot see it again**
6. Add it as `GHCR_PAT` secret to **every** repository

> **Note**: One PAT can be used across all repos. The token belongs to a GitHub user or org account.
> For production, create a dedicated machine account (bot user) rather than using a personal account.

---

## Section 2: Creating the SSH Deploy Key

Run this on your local machine (or the CI server):

```bash
# Generate a dedicated deploy key (no passphrase — CI needs unattended access)
ssh-keygen -t ed25519 -C "neps-deploy-ci" -f ~/.ssh/neps_deploy_key -N ""

# View the public key — add this to your server's authorized_keys
cat ~/.ssh/neps_deploy_key.pub

# View the private key — add this as DEPLOY_KEY secret in GitHub
cat ~/.ssh/neps_deploy_key
```

**On your production server:**
```bash
# Add the public key to the deploy user's authorized_keys
echo "your-public-key-here" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**In GitHub** (each repo):
- `DEPLOY_KEY` = contents of `~/.ssh/neps_deploy_key` (the **private** key, entire file including headers)
- `DEPLOY_HOST` = your server's IP or domain (e.g. `196.168.1.10` or `server.nepsdigital.org`)
- `DEPLOY_USER` = SSH username (e.g. `ubuntu`)

---

## Section 3: Repository Variables (Not Secrets)

Some non-sensitive values are stored as **Variables** (not secrets):

GitHub Repo → Settings → Secrets and variables → Actions → **Variables tab** → New repository variable

| Variable | Value | Purpose |
|---|---|---|
| `DEPLOY_HOST` | `your-server-ip` | Can also be a variable since it's not sensitive |

> The pipeline uses `vars.DEPLOY_HOST` — if this is not set, the deploy job skips gracefully.

---

## Section 4: Organization-Level Secrets (Recommended)

To avoid setting the same secret in every repo, use **GitHub Organization Secrets**:

1. Go to **GitHub Organization → Settings → Secrets and variables → Actions**
2. Add `GHCR_PAT`, `DEPLOY_KEY`, `DEPLOY_USER`, `DEPLOY_HOST` at org level
3. Choose **Repository access: Selected repositories** and grant access to all NEPS repos

This means updating one secret rotates it across all 4 repositories automatically.

---

## Section 5: Verify CI is Working

After setting secrets, trigger a pipeline:
```bash
# Push any change to trigger CI
git commit --allow-empty -m "chore: trigger CI verification"
git push origin main
```

**Expected pipeline stages for `neps-backend`:**
1. `check-structure` → detects `Dockerfile` + `requirements.txt` → sets `SKIP_BUILD=false`
2. `test` → installs deps, runs pytest (passes with "No tests yet" gracefully)
3. `build` → builds Docker image, pushes to `ghcr.io/nepsdigitalsystem/neps-backend:{sha}`
4. `security-scan` → Trivy scans the image, uploads results to GitHub Security tab
5. `deploy` → SSHs to server, pulls new image, runs `docker compose up -d --no-deps neps-backend`

**For `neps-ml-ai` and `neps-data-platform`** — pipelines will skip `build` until teams add their code.
The `check-structure` job detects the stub state and sets `SKIP_BUILD=true` automatically.

---

## Section 6: GHCR Package Visibility

After the first successful build, set the GHCR package visibility:

1. Go to **GitHub → Packages → `neps-backend`** (or other service)
2. Click **Package settings**
3. Under **Danger Zone** → Change visibility → **Private** (recommended for production)
4. Add each repository as a source (to allow CI to push)

---

## Quick Reference: All Secrets Checklist

```
□ neps-portal:       GHCR_PAT, DEPLOY_HOST, DEPLOY_USER, DEPLOY_KEY, NEXT_PUBLIC_API_URL
□ neps-backend:      GHCR_PAT, DEPLOY_HOST, DEPLOY_USER, DEPLOY_KEY
□ neps-ml-ai:        GHCR_PAT, DEPLOY_HOST, DEPLOY_USER, DEPLOY_KEY
□ neps-data-platform: GHCR_PAT, DEPLOY_HOST, DEPLOY_USER, DEPLOY_KEY
```
