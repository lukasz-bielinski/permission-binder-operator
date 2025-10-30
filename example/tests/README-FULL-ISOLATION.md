# E2E Tests - Full Isolation Mode

## Problem

Standard `run-all-individually.sh` może nie zawsze zapewniać **prawdziwą** pełną izolację między testami:
- Ten sam pod operatora przez wszystkie testy
- Accumulated state w kontrolerze
- Cache w Kubernetes API
- Metrics nie są resetowane

**Wynik:** Flaky tests - testy przechodzą przy re-run, ale failują w długim biegu.

## Rozwiązanie: `run-tests-full-isolation.sh`

Nowy skrypt zapewniający **GWARANTOWANĄ** pełną izolację dla każdego testu:

```
Test 1:
  1. CLEANUP: Usuń operator + CRD + wszystkie namespaces
  2. DEPLOY:  Deploy fresh operator (nowy pod!)
  3. RUN:     Uruchom test
  
Test 2:
  1. CLEANUP: Usuń operator + CRD + wszystkie namespaces
  2. DEPLOY:  Deploy fresh operator (nowy pod!)
  3. RUN:     Uruchom test

... (repeat dla każdego testu)
```

## Użycie

### 1. Wszystkie testy (pre + 1-34)

```bash
cd example/tests
./run-tests-full-isolation.sh
```

**Czas trwania:** ~70-90 minut (35 testów × 2-3 min)

### 2. Pojedynczy test

```bash
./run-tests-full-isolation.sh 3
```

**Czas trwania:** ~2 minuty

### 3. Wybrane testy

```bash
./run-tests-full-isolation.sh 3 7 11 16
```

**Czas trwania:** ~8 minut (4 testy × 2 min)

### 4. Re-run failed testów

Jeśli masz failed testy z poprzedniego runu:

```bash
# Z wczorajszego runu failed: 3, 7, 11, 16, 21, 26, 29
./run-tests-full-isolation.sh 3 7 11 16 21 26 29
```

**Czas trwania:** ~14 minut (7 testów × 2 min)

## Output i Logi

### Live Output

```
═════════════════════════════════════════════════════════════════
[1/7] Test 3: Exclude List Changes
═════════════════════════════════════════════════════════════════

🧹 Step 1/3: Cleaning cluster...
   ✅ Cluster cleaned
📦 Step 2/3: Deploying fresh operator...
   ✅ Operator ready
      Pod: operator-controller-manager-6d888866dd-h9jms
      Started: 2025-10-30T04:41:15Z
▶️  Step 3/3: Running test 3...

✅ Test 3 PASSED
✅ PASS: Namespace correctly not created (excluded by excludeList)
✅ PASS: No RoleBindings created for excluded namespace
✅ PASS: Valid namespace still exists

Progress: 1/7 (✅ 1 passed, ❌ 0 failed)
```

### Final Summary

```
═════════════════════════════════════════════════════════════════
📊 FINAL SUMMARY
═════════════════════════════════════════════════════════════════

✅ Test 3: Exclude List Changes - PASSED (pod: ...h9jms)
✅ Test 7: Namespace Protection - PASSED (pod: ...srxwx)
✅ Test 11: Invalid Configuration Handling - PASSED (pod: ...d5qtv)
✅ Test 16: Operator Permission Loss - PASSED (pod: ...djt6t)
✅ Test 21: Network Failure Simulation - PASSED (pod: ...xlfcc)
✅ Test 26: Metrics Update on Role Mapping - PASSED (pod: ...htxkm)
✅ Test 29: ConfigMap Processing Metrics - PASSED (pod: ...r7sbb)

═════════════════════════════════════════════════════════════════
Total Tests: 7
✅ Passed: 7
❌ Failed: 0
Success Rate: 100.0%

Results log: /tmp/e2e-full-isolation-20251030-053104.log
Individual logs:
  - Cleanup: /tmp/cleanup-<test_id>.log
  - Deploy:  /tmp/deploy-<test_id>.log
  - Test:    /tmp/test-<test_id>-isolated.log

Completed: Thu Oct 30 05:41:44 AM CET 2025
═════════════════════════════════════════════════════════════════

🎉 ALL TESTS PASSED!
```

### Log Files

Po uruchomieniu znajdziesz logi w `/tmp/`:

```bash
# Main results log
/tmp/e2e-full-isolation-20251030-053104.log

# Per-test logs
/tmp/cleanup-3.log      # Cleanup output dla Test 3
/tmp/deploy-3.log       # Deploy output dla Test 3
/tmp/test-3-isolated.log # Test execution output dla Test 3

# (Repeat dla każdego testu)
```

## Kiedy używać którego runnera?

| Runner | Izolacja | Czas | Użycie |
|--------|----------|------|--------|
| `test-runner.sh` | Brak | Sekundy | Quick test pojedynczego scenariusza |
| `run-all-individually.sh` | Średnia | ~40 min | Standard test run (ok dla większości) |
| `run-tests-full-isolation.sh` | **Pełna** | ~70-90 min | **Pre-release validation, debugging flaky tests** |

## Kiedy używać Full Isolation?

✅ **Używaj gdy:**
- Debugging flaky tests (testy które czasami failują)
- Pre-release validation (przed v1.x.0)
- Testy failowały w nightly run, ale przeszły przy re-run
- Chcesz mieć 100% pewność że operator działa stabilnie
- Sprawdzasz czy cleanup działa poprawnie

❌ **Nie używaj gdy:**
- Quick development iteration
- Debugging konkretnego testu (użyj `test-runner.sh <test_id>`)
- Mało czasu (użyj `run-all-individually.sh`)

## Różnice vs `run-all-individually.sh`

| Feature | run-all-individually.sh | run-tests-full-isolation.sh |
|---------|-------------------------|------------------------------|
| Cleanup per test | ✅ | ✅ |
| Deploy per test | ✅ | ✅ |
| **Fresh pod per test** | ⚠️  Może używać cache | ✅ **Gwarantowane** |
| **Verify pod running** | ✅ | ✅ |
| **Detailed logs per step** | ❌ | ✅ (cleanup, deploy, test) |
| **Pod name tracking** | ❌ | ✅ W summary |
| **Colored output** | ❌ | ✅ |
| Czas per test | ~1 min | ~2 min |
| **Use case** | Standard CI/CD | **Pre-release, debugging** |

## Przykłady

### Example 1: Quick pre-release check

```bash
# Sprawdź tylko "problematyczne" testy przed release
./run-tests-full-isolation.sh 16 21 26 29

# Testy security + network + metrics (często flaky)
```

### Example 2: Debug specific failed test

```bash
# Test 16 failował wczoraj, sprawdź z pełną izolacją
./run-tests-full-isolation.sh 16

# Sprawdź logi jeśli znowu failed
cat /tmp/cleanup-16.log
cat /tmp/deploy-16.log
cat /tmp/test-16-isolated.log
```

### Example 3: Nightly full validation

```bash
# Cron job - każdej nocy pełna validacja
0 2 * * * cd /path/to/tests && ./run-tests-full-isolation.sh > /var/log/e2e-nightly.log 2>&1
```

### Example 4: CI/CD Integration

```yaml
# .github/workflows/e2e-full-isolation.yml
name: E2E Tests - Full Isolation
on:
  schedule:
    - cron: '0 2 * * *'  # Nightly
  workflow_dispatch:     # Manual trigger

jobs:
  e2e-full-isolation:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v3
      - name: Run E2E Tests (Full Isolation)
        run: |
          cd example/tests
          ./run-tests-full-isolation.sh
```

## Troubleshooting

### Problem: Test failuje tylko w full isolation mode

**Diagnosis:**
- Test ma dependency na previous state
- Test nie czeka na async operations
- Race condition w teście

**Fix:**
Sprawdź test logic - powinien być **idempotent** i **self-contained**.

### Problem: Cleanup timeout

**Diagnosis:**
Namespace stuck in `Terminating` state.

**Fix:**
```bash
# Manual force cleanup
kubectl get ns | grep Terminating
kubectl delete namespace <ns> --force --grace-period=0
```

### Problem: Deploy fails (ImagePullBackOff)

**Diagnosis:**
Image nie istnieje lub nie ma multi-arch support.

**Fix:**
```bash
# Check Docker Hub
docker manifest inspect lukaszbielinski/permission-binder-operator:1.5.0

# Verify both amd64 and arm64 exist
```

## Best Practices

1. **Always use for pre-release validation**
   ```bash
   # Before tagging v1.x.0
   ./run-tests-full-isolation.sh
   ```

2. **Run overnight for full validation**
   ```bash
   nohup ./run-tests-full-isolation.sh > /tmp/nightly.log 2>&1 &
   ```

3. **Debug flaky tests individually**
   ```bash
   # Run flaky test 10 times
   for i in {1..10}; do
     echo "Run $i"
     ./run-tests-full-isolation.sh 16
   done
   ```

4. **Monitor resources during run**
   ```bash
   # Terminal 1
   ./run-tests-full-isolation.sh
   
   # Terminal 2
   watch -n 5 'kubectl get pods -A'
   ```

## Metrics and Performance

**Typical run time breakdown per test:**
- Cleanup: 30-40s
- Deploy: 20-30s
- Test execution: 30-60s
- **Total per test:** ~2 minutes

**Full suite (35 tests):**
- Best case: 70 minutes
- Typical: 80 minutes
- Worst case: 90 minutes

## Conclusion

`run-tests-full-isolation.sh` to **gold standard** dla E2E testing:
- ✅ Gwarantowana pełna izolacja
- ✅ Fresh pod per test (no cache!)
- ✅ Detailed logging
- ✅ Perfect dla pre-release validation

**Używaj przed każdym release aby mieć 100% pewność że operator działa stabilnie!**


