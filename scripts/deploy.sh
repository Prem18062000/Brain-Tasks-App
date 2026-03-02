#!/bin/bash
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${KUBE_NAMESPACE:-default}"
DEPLOYMENT_NAME="brain-tasks-app"
TIMEOUT=300
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Prerequisites check
check_prerequisites() {
  log_info "Checking prerequisites..."
  
  # Check if kubectl is installed
  if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed"
    exit 1
  fi
  
  # Check if kubectl is configured
  if ! kubectl cluster-info &> /dev/null; then
    log_error "kubectl is not connected to any cluster"
    exit 1
  fi
  
  # Check if namespace exists
  if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    log_warn "Namespace '$NAMESPACE' does not exist. Creating it..."
    kubectl create namespace "$NAMESPACE"
  fi
  
  log_info "Prerequisites check passed"
}

# Apply configuration files
apply_configs() {
  log_info "Applying Kubernetes manifests..."
  
  if [ ! -f "$SCRIPT_DIR/k8s/app/deployment.yaml" ]; then
    log_error "deployment.yaml not found at $SCRIPT_DIR/k8s/app/deployment.yaml"
    exit 1
  fi
  
  if [ ! -f "$SCRIPT_DIR/k8s/app/service.yaml" ]; then
    log_error "service.yaml not found at $SCRIPT_DIR/k8s/app/service.yaml"
    exit 1
  fi
  
  kubectl apply -f "$SCRIPT_DIR/k8s/app/deployment.yaml" -n "$NAMESPACE"
  log_info "Deployment manifest applied successfully"
  
  kubectl apply -f "$SCRIPT_DIR/k8s/app/service.yaml" -n "$NAMESPACE"
  log_info "Service manifest applied successfully"
}

# Deploy monitoring (if exists)
deploy_monitoring() {
  if [ -d "$SCRIPT_DIR/k8s/monitoring" ]; then
    log_info "Deploying monitoring components..."
    
    for manifest in "$SCRIPT_DIR/k8s/monitoring"/*.yaml; do
      if [ -f "$manifest" ]; then
        kubectl apply -f "$manifest" -n "$NAMESPACE"
        log_info "Applied $(basename "$manifest")"
      fi
    done
  fi
}

# Wait for deployment to be ready
wait_for_deployment() {
  log_info "Waiting for deployment to be ready (timeout: ${TIMEOUT}s)..."
  
  if kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
    log_info "Deployment is ready"
  else
    log_error "Deployment failed to become ready within ${TIMEOUT}s"
    log_info "Current deployment status:"
    kubectl describe deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE"
    exit 1
  fi
}

# Get deployment info
show_deployment_info() {
  log_info "Deployment Information:"
  echo "---"
  kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE"
  echo ""
  log_info "Service Information:"
  kubectl get service brain-tasks-service -n "$NAMESPACE"
  echo ""
  log_info "Pod Status:"
  kubectl get pods -n "$NAMESPACE" -l app=brain-tasks
}

# Main execution
main() {
  echo "=========================================="
  echo "Brain Tasks App - Deployment Script"
  echo "=========================================="
  echo ""
  
  check_prerequisites
  apply_configs
  deploy_monitoring
  wait_for_deployment
  show_deployment_info
  
  echo ""
  log_info "Deployment Completed Successfully!"
  echo "=========================================="
}

trap 'log_error "Deployment failed"; exit 1' ERR

main
