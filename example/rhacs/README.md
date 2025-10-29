# RHACS (Red Hat Advanced Cluster Security) Configuration

This directory contains GitOps-ready configuration for deploying and configuring RHACS to verify Cosign signatures for the Permission Binder Operator.

## Prerequisites

- OpenShift Container Platform 4.11+
- Red Hat Advanced Cluster Security license
- Cluster admin access
- At least 16GB RAM available for RHACS components

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenShift Cluster                        │
│                                                             │
│  ┌────────────────┐         ┌──────────────────┐          │
│  │   RHACS        │         │  Admission       │          │
│  │   Central      │◄────────┤  Controller      │          │
│  │   (rhacs-operator)   │         │  (webhook)       │          │
│  └────────────────┘         └──────────────────┘          │
│         │                            │                     │
│         │                            │                     │
│         ▼                            ▼                     │
│  ┌────────────────┐         ┌──────────────────┐          │
│  │   Scanner      │         │  Deploy Request  │          │
│  │   (CVE scan)   │         │  (validate sigs) │          │
│  └────────────────┘         └──────────────────┘          │
│                                      │                     │
│                                      ▼                     │
│                            ┌──────────────────┐            │
│                            │  Verify Cosign   │            │
│                            │  Signature       │            │
│                            └──────────────────┘            │
│                                      │                     │
│                            ┌─────────┴──────────┐          │
│                            │                    │          │
│                            ▼                    ▼          │
│                         ✅ Allow            ❌ Deny        │
└─────────────────────────────────────────────────────────────┘
```

## Installation Steps

### 1. Install RHACS Operator

```bash
oc apply -f 01-namespace.yaml
oc apply -f 02-operator-group.yaml
oc apply -f 03-subscription.yaml

# Wait for operator to be ready
oc wait --for=condition=Available --timeout=300s \
  deployment/rhacs-operator -n rhacs-operator
```

### 2. Deploy RHACS Central

```bash
oc apply -f 04-central.yaml

# Wait for Central to be ready (can take 5-10 minutes)
oc wait --for=condition=Available --timeout=600s \
  deployment/central -n rhacs-operator

# Get Central route and admin password
export RHACS_ROUTE=$(oc get route central -n rhacs-operator -o jsonpath='{.spec.host}')
export RHACS_PASSWORD=$(oc get secret central-htpasswd -n rhacs-operator -o jsonpath='{.data.password}' | base64 -d)

echo "RHACS Central URL: https://${RHACS_ROUTE}"
echo "Admin password: ${RHACS_PASSWORD}"
```

### 3. Deploy Secured Cluster (Admission Controller)

```bash
oc apply -f 05-secured-cluster.yaml

# Wait for sensor and admission controller
oc wait --for=condition=Available --timeout=300s \
  deployment/sensor -n rhacs-operator
oc wait --for=condition=Available --timeout=300s \
  deployment/admission-control -n rhacs-operator
```

### 4. Configure Cosign Integration

```bash
# Option A: Via Web UI (recommended for first setup)
# 1. Login to https://${RHACS_ROUTE}
# 2. Go to Platform Configuration → Integrations
# 3. Click "Signature Integrations" → "New Integration"
# 4. Select "Cosign"
# 5. Fill in the configuration from cosign-integration-config.yaml

# Option B: Via API (for GitOps)
# First, create an API token in the UI:
# Platform Configuration → Integrations → API Token → Generate Token

export ROX_API_TOKEN="<your-api-token>"

# Apply the integration
./scripts/apply-cosign-integration.sh
```

### 5. Apply Image Signature Verification Policy

```bash
# Option A: Import via Web UI
# 1. Go to Platform Configuration → Policy Management
# 2. Click "Import Policy"
# 3. Upload: policies/01-signature-verification-policy.json

# Option B: Via roxctl CLI
roxctl --endpoint "${RHACS_ROUTE}:443" \
  --password "${RHACS_PASSWORD}" \
  central policy import \
  --file policies/01-signature-verification-policy.json
```

### 6. Test the Configuration

```bash
# Deploy the operator (should succeed with valid signature)
oc apply -k ../

# Try to deploy an unsigned image (should be blocked)
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-unsigned
  namespace: permissions-binder-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
EOF
# Expected: Admission webhook denied the request
```

## Files Description

| File | Purpose |
|------|---------|
| `01-namespace.yaml` | Create rhacs-operator namespace |
| `02-operator-group.yaml` | Configure operator scope |
| `03-subscription.yaml` | Install RHACS operator from Red Hat catalog |
| `04-central.yaml` | Deploy RHACS Central (main server) |
| `05-secured-cluster.yaml` | Deploy Sensor + Admission Controller |
| `cosign-integration-config.yaml` | Cosign signature integration configuration |
| `policies/01-signature-verification-policy.json` | Policy to enforce signature verification |
| `policies/02-cve-policy.json` | Additional CVE scanning policy |
| `scripts/apply-cosign-integration.sh` | Script to configure Cosign via API |
| `scripts/verify-setup.sh` | Script to verify RHACS is working correctly |

## Configuration Details

### Cosign Integration

The Cosign integration is configured for **keyless signing** with GitHub Actions:

- **Certificate Identity Regexp**: `https://github.com/lukasz-bielinski/permission-binder-operator/.*`
- **OIDC Issuer**: `https://token.actions.githubusercontent.com`
- **Rekor URL**: `https://rekor.sigstore.dev`

This validates that images were built and signed by the official GitHub Actions workflow.

### Signature Verification Policy

The policy enforces:

1. **All images** in `permissions-binder-operator` namespace **must be signed**
2. Signature must be verified by the "GitHub Actions Cosign" integration
3. Only images from `docker.io/lukaszbielinski/permission-binder-operator` are allowed
4. Enforcement at **DEPLOY** lifecycle stage (admission control)
5. Action: **FAIL_KUBE_REQUEST_ENFORCEMENT** (block deployment)

### Network Policies

RHACS automatically creates network policies for:
- Sensor → Central communication
- Admission Controller → Central communication
- Scanner → Internet (for CVE database updates)

## Monitoring and Alerts

After setup, you can monitor in RHACS UI:

1. **Violations**: Platform Configuration → Violations
   - Shows blocked deployments due to missing/invalid signatures

2. **Risk**: Risk → Deployments
   - Risk score for each deployment
   - CVE information
   - Policy violations

3. **Network**: Network Graph
   - Visualize actual network traffic
   - Detect anomalies

## Troubleshooting

### Admission Controller Not Blocking Invalid Images

```bash
# Check admission controller logs
oc logs deployment/admission-control -n rhacs-operator

# Verify webhook is registered
oc get validatingwebhookconfigurations | grep rhacs-operator

# Check policy is enabled
oc get configmap -n rhacs-operator
```

### Cosign Verification Failing

```bash
# Test signature manually
cosign verify \
  --certificate-identity-regexp "https://github.com/lukasz-bielinski/permission-binder-operator" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  lukaszbielinski/permission-binder-operator:1.4.0

# Check RHACS can reach Rekor
oc exec -n rhacs-operator deployment/central -- curl -I https://rekor.sigstore.dev
```

### Central Not Starting

```bash
# Check events
oc get events -n rhacs-operator --sort-by='.lastTimestamp'

# Check persistent volume
oc get pvc -n rhacs-operator

# Check resources
oc describe pod -l app=central -n rhacs-operator
```

## Maintenance

### Update RHACS

```bash
# Update operator (automatic via subscription)
# Central will be updated automatically by operator

# Or manually approve update
oc get installplan -n rhacs-operator
oc patch installplan <install-plan-name> -n rhacs-operator \
  --type merge -p '{"spec":{"approved":true}}'
```

### Backup Central Data

```bash
# Create backup
oc exec -n rhacs-operator deployment/central -- \
  /rhacs-operator/central backup --output-file /tmp/backup.zip

# Copy backup
oc cp rhacs-operator/central-<pod-id>:/tmp/backup.zip ./rhacs-backup-$(date +%Y%m%d).zip
```

## Additional Resources

- [RHACS Documentation](https://docs.openshift.com/acs/)
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Policy Examples](https://github.com/rhacs-operator/contributions/tree/main/policy-examples)
- [RHACS Community](https://github.com/rhacs-operator/rhacs-operator)

## Support

For RHACS support:
- Red Hat Support Portal: https://access.redhat.com/support
- RHACS Product Documentation: https://docs.openshift.com/acs/

For Permission Binder Operator issues:
- GitHub Issues: https://github.com/lukasz-bielinski/permission-binder-operator/issues

