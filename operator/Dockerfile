# Build the manager binary
FROM golang:1.24 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY cmd/main.go cmd/main.go
COPY api/ api/
COPY internal/controller/ internal/controller/

# Build
# the GOARCH has not a default value to allow the binary be built according to the host where the command
# was called. For example, if we call make docker-build in a local env which has the Apple Silicon M1 SO
# the docker BUILDPLATFORM arg will be linux/arm64 when for Apple x86 it will be linux/amd64. Therefore,
# by leaving it empty we can ensure that the container and binary shipped on it will have the same platform.
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -a -o manager cmd/main.go

# Use alpine as base image to include git for NetworkPolicy GitOps operations
# Alpine is minimal and secure, and includes git which is required for cloning repositories
FROM alpine:3.19
RUN apk --no-cache add ca-certificates git
WORKDIR /
COPY --from=builder /workspace/manager .
# Create non-root user (65532:65532 matches distroless nonroot user)
RUN addgroup -g 65532 nonroot && adduser -D -u 65532 -G nonroot nonroot
USER 65532:65532

ENTRYPOINT ["/manager"]
