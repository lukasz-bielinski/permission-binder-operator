#!/bin/bash

# Multi-architecture build script for Permission Binder Operator
# This script builds and pushes Docker images for both aarch64 and x86_64 architectures

set -e

# Configuration
IMAGE_NAME="lukaszbielinski/permission-binder-operator"
VERSION=${1:-"latest"}
PLATFORMS="linux/arm64,linux/amd64"

echo "🚀 Building multi-architecture Docker image"
echo "Image: ${IMAGE_NAME}:${VERSION}"
echo "Platforms: ${PLATFORMS}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker daemon is not running. Please start Docker first:"
    echo "   sudo systemctl start docker"
    exit 1
fi

# Check if logged in to Docker Hub
if ! docker info | grep -q "Username"; then
    echo "⚠️  You may need to login to Docker Hub first:"
    echo "   docker login"
fi

# Create buildx builder if it doesn't exist
echo "🔧 Setting up buildx builder..."
docker buildx create --name operator-builder --use 2>/dev/null || docker buildx use operator-builder

# Build and push multi-architecture image
echo "🏗️  Building and pushing multi-architecture image..."
docker buildx build \
    --platform ${PLATFORMS} \
    --tag ${IMAGE_NAME}:${VERSION} \
    --push \
    .

echo "✅ Multi-architecture image built and pushed successfully!"
echo "Image: ${IMAGE_NAME}:${VERSION}"
echo ""
echo "To verify the image supports multiple architectures:"
echo "docker buildx imagetools inspect ${IMAGE_NAME}:${VERSION}"
