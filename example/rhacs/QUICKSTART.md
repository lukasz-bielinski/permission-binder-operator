# RHACS Quick Start Guide

Fast track to get RHACS running with Cosign signature verification for Permission Binder Operator.

## Prerequisites Checklist

- [ ] OpenShift 4.11+ cluster
- [ ] Cluster admin access
- [ ] RHACS license/subscription
- [ ] At least 16GB RAM available
- [ ] Internet connectivity (for pulling images and Rekor access)

## 🚀 Quick Installation (15 minutes)

### Step 1: Deploy RHACS (5 minutes)

```bash
# Clone or navigate to this directory
cd example/rhacs

# Deploy everything via Kustomize
oc apply -k .

# Wait for operator
oc wait --for=condition=Available --timeout=300s \
  deployment/rhacs-operator -n rhacs-operator

echo "✅ Operator installed"
```

### Step 2: Wait for Central (5-10 minutes)

```bash
# Monitor Central deployment
watch oc get pods -n rhacs-operator

# Wait for Central to be ready
oc wait --for=condition=Available --timeout=600s \
  deployment/central -n rhacs-operator

# Get credentials
export RHACS_ROUTE=$(oc get route central -n rhacs-operator -o jsonpath='{.spec.host}')
export RHACS_PASSWORD=$(oc get secret central-htpasswd -n rhacs-operator -o jsonpath='{.data.password}' | base64 -d)

echo ""
echo "✅ RHACS Central is ready!"
echo "   URL: https://${RHACS_ROUTE}"
echo "   Username: admin"
echo "   Password: ${RHACS_PASSWORD}"
echo ""
```

### Step 3: Wait for Admission Controller (2-3 minutes)

```bash
# Wait for admission control
oc wait --for=condition=Available --timeout=300s \
  deployment/admission-control -n rhacs-operator

echo "✅ Admission Controller ready"
```

### Step 4: Configure Cosign Integration (2 minutes)

**Option A: Web UI (Recommended for first time)**

1. Login to `https://${RHACS_ROUTE}` with credentials from Step 2
2. Navigate: **Platform Configuration** → **Integrations**
3. Click: **Signature Integrations** → **New Integration**
4. Select: **Cosign**
5. Configure:
   - **Integration Name**: `GitHub Actions Cosign`
   - **Public Key**: *(leave empty for keyless)*
   - **Certificate OIDC Issuer**: `https://token.actions.githubusercontent.com`
   - **Certificate Identity**: Use regex pattern
     ```
     ^https://github\.com/lukasz-bielinski/permission-binder-operator/.*
     ```
   - **Rekor Public Key**: *(use default)*
6. Click **Test** (optional)
7. Click **Save**

**Option B: Automated via Script**

```bash
# Generate API token first in RHACS UI:
# Platform Configuration → Integrations → API Token → Generate Token
# Name: "GitOps", Role: Admin

export ROX_API_TOKEN="<your-token>"

# Run script
./scripts/apply-cosign-integration.sh
```

### Step 5: Apply Policies (1 minute)

```bash
# Apply signature verification and CVE policies
export ROX_API_TOKEN="<your-token>"  # if not set
./scripts/apply-policies.sh
```

## ✅ Verification

### Test 1: Verify Setup

```bash
./scripts/verify-setup.sh
```

### Test 2: Deploy Signed Image (Should Succeed)

```bash
# Deploy permission-binder-operator
cd ../..
oc apply -k example/

# Check deployment
oc get pods -n permissions-binder-operator
```

**Expected**: Deployment succeeds, operator pod is running ✅

### Test 3: Try Unsigned Image (Should Fail)

```bash
# Try to deploy unsigned nginx
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
```

**Expected**: Admission webhook denies the request ❌

```
Error from server: admission webhook "policyeval.rhacs-operator.io" denied the request: 
The deployment violated 1 policy:
Policy: Permission Binder Operator - Signature Verification
- Description: Image signature not verified
```

## 📊 Monitoring

### View in RHACS UI

1. **Dashboard**: Overview of cluster security posture
2. **Violations**: View denied deployments
   - Navigate: **Violations** tab
   - Filter by policy name
3. **Risk**: View deployment risk scores
   - Navigate: **Risk** → **Deployments**
4. **Network**: Visualize network topology
   - Navigate: **Network Graph**

### CLI Monitoring

```bash
# Check admission controller logs
oc logs -l app=admission-control -n rhacs-operator --tail=50 -f

# Check for violations
oc get events -n permissions-binder-operator | grep rhacs-operator

# View RHACS alerts
roxctl --endpoint "${RHACS_ROUTE}:443" \
  --token-file <(echo -n "${ROX_API_TOKEN}") \
  central alerts list
```

## 🔧 Troubleshooting

### Admission Controller Not Blocking

```bash
# Check webhook configuration
oc get validatingwebhookconfigurations | grep rhacs-operator

# Check admission controller logs
oc logs deployment/admission-control -n rhacs-operator | tail -50

# Verify policy is enabled
# RHACS UI → Policy Management → Search for "Permission Binder"
```

### Cosign Verification Failing

```bash
# Test manually with cosign CLI
cosign verify \
  --certificate-identity-regexp "https://github.com/lukasz-bielinski/permission-binder-operator" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  docker.io/lukaszbielinski/permission-binder-operator:1.4.0

# Check RHACS can reach Rekor
oc exec -n rhacs-operator deployment/central -- curl -I https://rekor.sigstore.dev
```

### Central Not Starting

```bash
# Check PVC
oc get pvc -n rhacs-operator

# Check pod events
oc describe pod -l app=central -n rhacs-operator

# Check logs
oc logs -l app=central -n rhacs-operator --tail=100
```

## 🎯 Next Steps

1. **Review Violations**: Check RHACS UI for any policy violations
2. **Customize Policies**: Adjust policies based on your security requirements
3. **Add More Integrations**: Configure Slack/Email notifications
4. **Network Policies**: Review and apply RHACS-recommended network policies
5. **Compliance**: Run compliance scans (PCI-DSS, NIST, etc.)

## 📚 Additional Resources

- Full setup guide: `README.md`
- RHACS Documentation: https://docs.openshift.com/acs/
- Policy examples: `policies/`
- Scripts: `scripts/`

## 🆘 Support

- **RHACS Issues**: Red Hat Support Portal
- **Operator Issues**: https://github.com/lukasz-bielinski/permission-binder-operator/issues

---

**Time to full deployment**: ~15 minutes  
**Difficulty**: Intermediate  
**Impact**: High security assurance with zero node restarts! 🎉

