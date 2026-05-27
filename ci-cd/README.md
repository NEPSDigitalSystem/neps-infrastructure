# NEPS CI/CD Templates

This directory contains the standardized GitHub Actions workflow templates for all NEPS Digital repositories.

## 🚀 How to use these templates

Each team should copy the appropriate template into their repository's `.github/workflows/` directory.

### For example:
If you are working on `neps-backend`:
1. Create the directory: `mkdir -p .github/workflows/` in your repo
2. Copy `backend-ci.yml` from here to `.github/workflows/main.yml` in your repo
3. Update any specific environment variables or test commands if needed.

## 📋 Required Repository Secrets
Before the workflows will run successfully, an organization admin must configure the following secrets in the GitHub Organization (or individually in each repo):

- `GHCR_PAT`: A Personal Access Token (or specific GitHub Token) with `write:packages` permission to push to the GitHub Container Registry (`ghcr.io`).

## 🐳 Container Registry
All images are built and pushed to `ghcr.io/nepsdigitalsystem/[repo-name]`.
