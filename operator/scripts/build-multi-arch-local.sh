#!/bin/bash

# Multi-architecture build script for Permission Binder Operator (local only)
# This script builds Docker images for both aarch64 and x86_64 architectures locally

set -e

# Configuration
IMAGE_NAME="lukaszbielinski/permission-binder-operator"
VERSION=${1:-"latest"}
PLATFORMS="linux/arm64,linux/amd64"

echo "🚀 Building multi-architecture Docker image locally"
echo "Image: ${IMAGE_NAME}:${VERSION}"
echo "Platforms: ${PLATFORMS}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker daemon is not running. Please start Docker first:"
    echo "   sudo systemctl start docker"
    exit 1
fi

# Create buildx builder if it doesn't exist
echo "🔧 Setting up buildx builder..."
docker buildx create --name operator-builder --use 2>/dev/null || docker buildx use operator-builder

# Build multi-architecture image locally
echo "🏗️  Building multi-architecture image locally..."
docker buildx build \
    --platform ${PLATFORMS} \
    --tag ${IMAGE_NAME}:${VERSION} \
    --load \
    .

echo "✅ Multi-architecture image built successfully!"
echo "Image: ${IMAGE_NAME}:${VERSION}"
echo ""
echo "To verify the image:"
echo "docker images ${IMAGE_NAME}:${VERSION}"
echo ""
echo "To push the image to registry:"
echo "docker push ${IMAGE_NAME}:${VERSION}"
