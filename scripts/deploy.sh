#!/bin/bash
set -e

echo "Applying Deployment..."
kubectl apply -f k8s/deployment.yaml

echo "Applying Service..."
kubectl apply -f k8s/service.yaml

echo "Rolling Update..."
kubectl rollout restart deployment/brain-tasks-deploy

echo "Deployment Completed!"
