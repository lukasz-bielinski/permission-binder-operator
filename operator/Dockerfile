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
# Note: git-askpass-helper is no longer needed - go-git uses BasicAuth directly
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -a -o manager cmd/main.go

# Use distroless static image - pure Go implementation (go-git) doesn't need git binary
# distroless/static:nonroot provides maximum security (no shell, no package manager, minimal attack surface)
# go-git is a pure Go library, so we don't need git binary or any system dependencies
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static:nonroot
WORKDIR /
# Copy manager binary (statically linked Go binary)
COPY --from=builder /workspace/manager .
# Note: git-askpass-helper is no longer needed - go-git uses BasicAuth directly
USER 65532:65532

ENTRYPOINT ["/manager"]
