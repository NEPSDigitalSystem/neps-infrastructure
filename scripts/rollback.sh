#!/bin/bash
set -euo pipefail

# NEPS Digital — Blue-Green Rollback Script
# Usage: ./rollback.sh [blue|green|previous|specific-sha]

ENVIRONMENT=${1:-previous}
ORG="nepsdigitalsystem"
COMPOSE_FILE="docker-compose.yml"
REGISTRY="ghcr.io/$ORG"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[ROLLBACK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Get current active color from nginx config
get_active_color() {
    grep -oP 'server neps-\K(blue|green)' nginx/nginx.conf | head -1 || echo "blue"
}

# Get previous successful deployment SHA
get_previous_sha() {
    cat .deployment-history/current.sha 2>/dev/null || echo "latest"
}

# Save deployment state
save_state() {
    mkdir -p .deployment-history
    echo "$1" > .deployment-history/current.sha
    date -Iseconds >> .deployment-history/history.log
}

# Health check with timeout
health_check() {
    local url=$1
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -sf "$url/health" > /dev/null 2>&1; then
            log "Health check passed: $url"
            return 0
        fi
        warn "Health check attempt $attempt/$max_attempts failed..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    error "Health check failed after $max_attempts attempts"
}

# Main rollback logic
case $ENVIRONMENT in
    blue|green)
        TARGET_COLOR=$ENVIRONMENT
        log "Rolling to $TARGET_COLOR environment..."
        ;;
    
    previous)
        TARGET_SHA=$(get_previous_sha)
        log "Rolling back to previous SHA: $TARGET_SHA"
        ;;
    
    specific-sha)
        TARGET_SHA=${2:-$(get_previous_sha)}
        log "Rolling to specific SHA: $TARGET_SHA"
        
        # Pull specific image tags
        for service in neps-portal neps-backend neps-ml-ai neps-data-platform; do
            docker pull "$REGISTRY/$service:$TARGET_SHA" || error "Failed to pull $service:$TARGET_SHA"
            docker tag "$REGISTRY/$service:$TARGET_SHA" "$REGISTRY/$service:rollback-target"
        done
        ;;
    
    *)
        error "Usage: $0 [blue|green|previous|specific-sha <sha>]"
        ;;
esac

# For blue-green, switch traffic
if [ "$ENVIRONMENT" = "blue" ] || [ "$ENVIRONMENT" = "green" ]; then
    # Update nginx to point to target color
    sed -i "s/server neps-(blue|green)/server neps-$TARGET_COLOR/g" nginx/nginx.conf
    
    # Reload nginx without dropping connections
    docker-compose exec -T nginx nginx -s reload
    
    log "Traffic switched to $TARGET_COLOR"
    save_state "$TARGET_COLOR"
fi

# For SHA-based rollback, restart services
if [ "$ENVIRONMENT" = "previous" ] || [ "$ENVIRONMENT" = "specific-sha" ]; then
    log "Stopping current services..."
    docker-compose down
    
    log "Starting rollback services with target images..."
    TARGET_SHA=${TARGET_SHA:-$(get_previous_sha)}
    export IMAGE_TAG=$TARGET_SHA
    docker-compose -f docker-compose.yml -f docker-compose.rollback.yml up -d
    
    # Verify health
    sleep 5
    health_check "http://localhost:8000"  # Backend
    health_check "http://localhost:3000"  # Portal
    
    save_state "$TARGET_SHA"
    log "Rollback to $TARGET_SHA completed successfully!"
fi

log "Rollback complete. Current state: $(get_active_color)"
