# Bitbucket Server Authentication Troubleshooting

## Problem: "failed authentication" with Bitbucket Server

If you're getting authentication errors when using Bitbucket Server with the Permission Binder Operator, follow these troubleshooting steps:

---

## ✅ Quick Checklist

1. [ ] **Username is set** in Secret (required for Bitbucket Server)
2. [ ] **Token is App Password** (not regular password)
3. [ ] **Provider is set** to `"bitbucket"` in PermissionBinder spec
4. [ ] **TLS verification** - if self-signed certs, set `gitTlsVerify: false`
5. [ ] **URL format** is correct (HTTPS, no credentials in URL)
6. [ ] **Token has correct permissions** (repository read/write)

---

## 🔍 Common Issues & Solutions

### 1. Missing Username

**Problem**: Bitbucket Server requires username, not just token.

**Solution**: Ensure Secret contains `username` field:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bitbucket-gitops-credentials
  namespace: permissions-binder-operator
type: Opaque
stringData:
  token: "YOUR_APP_PASSWORD"
  username: "your-bitbucket-username"  # ⚠️ REQUIRED for Bitbucket Server
  email: "operator@example.com"
```

**Verify**:
```bash
kubectl get secret bitbucket-gitops-credentials -n permissions-binder-operator -o jsonpath='{.data.username}' | base64 -d
```

---

### 2. Wrong Token Type

**Problem**: Using regular password instead of App Password/Personal Access Token.

**Solution**: Create App Password in Bitbucket Server:
1. Go to **Personal Settings** → **App Passwords**
2. Create new App Password with permissions:
   - **Repositories**: Read, Write
   - **Pull requests**: Write
3. Copy the generated password (shown only once)
4. Use it as `token` in Secret

**Note**: For Bitbucket Server, you may need to use Personal Access Token instead of App Password, depending on your version.

---

### 3. Self-Signed TLS Certificate

**Problem**: Bitbucket Server uses self-signed certificate, causing TLS verification errors.

**Solution**: Set `gitTlsVerify: false` in PermissionBinder spec:

```yaml
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-bitbucket
spec:
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "bitbucket"
      url: "https://bitbucket.example.com/scm/project/repo.git"
      gitTlsVerify: false  # ⚠️ For self-signed certificates only
      # ... rest of config
```

**Security Warning**: Only use `gitTlsVerify: false` for self-signed certificates in trusted environments. Never use in production with valid certificates.

---

### 4. Provider Not Set

**Problem**: Operator can't auto-detect Bitbucket Server from URL.

**Solution**: Explicitly set `provider: "bitbucket"`:

```yaml
gitRepository:
  provider: "bitbucket"  # ⚠️ REQUIRED for self-hosted Bitbucket Server
  url: "https://bitbucket.example.com/scm/project/repo.git"
```

---

### 5. Incorrect URL Format

**Problem**: URL contains credentials or wrong format.

**Solution**: Use clean HTTPS URL without credentials:

```yaml
# ✅ CORRECT
url: "https://bitbucket.example.com/scm/project/repo.git"

# ❌ WRONG - Don't include credentials in URL
url: "https://user:pass@bitbucket.example.com/scm/project/repo.git"
```

The operator uses `GIT_ASKPASS` to provide credentials securely.

---

### 6. Token Permissions

**Problem**: Token doesn't have required permissions.

**Solution**: Ensure token has:
- **Repositories**: Read, Write
- **Pull requests**: Write (for PR creation)

---

## 🔧 Debugging Steps

### Step 1: Check Operator Logs

```bash
kubectl logs -n permissions-binder-operator deployment/operator-controller-manager | grep -i "clone\|auth\|git"
```

Look for:
- `"failed to clone repository"`
- `"authentication failed"`
- `"fatal: Authentication failed"`

### Step 2: Verify Secret

```bash
# Check if Secret exists
kubectl get secret bitbucket-gitops-credentials -n permissions-binder-operator

# Verify username is set
kubectl get secret bitbucket-gitops-credentials -n permissions-binder-operator -o jsonpath='{.data.username}' | base64 -d
echo

# Verify token is set (don't print full token)
kubectl get secret bitbucket-gitops-credentials -n permissions-binder-operator -o jsonpath='{.data.token}' | base64 -d | wc -c
```

### Step 3: Test Git Clone Manually

Test if credentials work outside the operator:

```bash
# Set environment variables
export GIT_HTTP_USER="your-username"
export GIT_HTTP_PASSWORD="your-app-password"
export GIT_ASKPASS="echo"
export GIT_TERMINAL_PROMPT=0

# For self-signed certs
export GIT_SSL_NO_VERIFY=true

# Test clone
git clone --depth 1 https://bitbucket.example.com/scm/project/repo.git /tmp/test-clone
```

If this fails, the problem is with credentials, not the operator.

### Step 4: Check PermissionBinder Status

```bash
kubectl get permissionbinder -n permissions-binder-operator -o yaml | grep -A 20 "networkPolicy"
```

Verify:
- `provider: "bitbucket"` is set
- `gitTlsVerify: false` if using self-signed certs
- `credentialsSecretRef` points to correct Secret

---

## 📝 Complete Working Example

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bitbucket-gitops-credentials
  namespace: permissions-binder-operator
type: Opaque
stringData:
  token: "YOUR_APP_PASSWORD_OR_PAT"
  username: "your-bitbucket-username"  # Required!
  email: "operator@example.com"
---
apiVersion: permission.permission-binder.io/v1
kind: PermissionBinder
metadata:
  name: permissionbinder-bitbucket
  namespace: permissions-binder-operator
spec:
  # ... other config ...
  networkPolicy:
    enabled: true
    gitRepository:
      provider: "bitbucket"  # Required for self-hosted
      url: "https://bitbucket.example.com/scm/project/repo.git"
      baseBranch: "main"
      clusterName: "PROD-cluster"
      gitTlsVerify: false  # Only if self-signed certs
      apiBaseURL: "https://bitbucket.example.com/rest/api/1.0"  # Optional
      credentialsSecretRef:
        name: "bitbucket-gitops-credentials"
        namespace: "permissions-binder-operator"
```

---

## 🚨 Still Not Working?

If authentication still fails after following all steps:

1. **Check Bitbucket Server logs**:
   - Location: `$BITBUCKET_HOME/log/audit/`
   - Look for failed authentication attempts

2. **Verify network connectivity**:
   ```bash
   kubectl exec -n permissions-binder-operator deployment/operator-controller-manager -- \
     curl -k https://bitbucket.example.com/rest/api/1.0/projects
   ```

3. **Check if 2FA is enabled**:
   - If 2FA is enabled, you MUST use App Password, not regular password

4. **Verify Bitbucket Server version**:
   - Older versions may have different authentication requirements
   - Check Bitbucket Server documentation for your version

5. **Try with `gitTlsVerify: false`**:
   - Even if you think certs are valid, try disabling TLS verification temporarily to rule out certificate issues

---

## 📚 References

- [Bitbucket Server App Passwords](https://confluence.atlassian.com/bitbucketserver/personal-access-tokens-939515499.html)
- [Git Credential Helper](https://git-scm.com/docs/gitcredentials)
- [Operator Git Operations](https://github.com/lukasz-bielinski/permission-binder-operator)

