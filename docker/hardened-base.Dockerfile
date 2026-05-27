# neps-infrastructure/docker/hardened-base.Dockerfile
# Use this as base for all NEPS services

FROM python:3.11-slim

# Security: Update packages
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Security: Create non-root user
RUN groupadd -r neps -g 1000 && \
    useradd -r -g neps -u 1000 neps

# Security: Set strict permissions
RUN mkdir -p /app && chown -R neps:neps /app
WORKDIR /app

# Security: No shell access
RUN usermod -s /sbin/nologin neps

# Copy and install as root, then switch
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chown -R neps:neps /app

# Security: Drop to non-root
USER neps

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000
