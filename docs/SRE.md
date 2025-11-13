# Site Reliability Engineering (SRE) Documentation

**Version:** 1.0  
**Last Updated:** 2025-01-13  
**Maintainer:** Platform Team

---

## Service Level Objectives (SLOs)

### Availability SLO

**Target:** 99.9% availability (43 minutes downtime/month)

**Measurement:**
```promql
# Success rate over 30-minute window
1 - (
  rate(controller_runtime_reconcile_errors_total{controller="permissionbinder"}[30m])
  /
  rate(controller_runtime_reconcile_total{controller="permissionbinder"}[30m])
)
```

**SLI (Service Level Indicator):**
- Successful reconciliations / Total reconciliations
- Measured over rolling 30-day window
- Excludes planned maintenance windows

### Latency SLO

**Target:** 95% of reconciliations complete within 30 seconds

**Measurement:**
```promql
# 95th percentile reconciliation duration
histogram_quantile(0.95,
  rate(controller_runtime_reconcile_time_seconds_bucket{controller="permissionbinder"}[5m])
)
```

**SLI:**
- Reconciliation duration (p95)
- Measured over rolling 7-day window

### Correctness SLO

**Target:** 100% of RoleBindings match desired state

**Measurement:**
```promql
# Drift detection events (should be 0)
permission_binder_drift_detection_events_total
```

**SLI:**
- (Total RoleBindings - Drift Events) / Total RoleBindings
- Measured over rolling 30-day window

---

## Error Budgets

### Monthly Error Budget Calculation

**Availability Error Budget:**
```
Total minutes per month: 43,200
Allowed downtime (99.9% SLO): 43 minutes
Error budget: 43 minutes
```

**Error Budget Tracking:**
```promql
# Error budget remaining (as percentage)
(
  1 - (
    rate(controller_runtime_reconcile_errors_total{controller="permissionbinder"}[30d])
    /
    rate(controller_runtime_reconcile_total{controller="permissionbinder"}[30d])
  )
) * 100
```

**Error Budget Policy:**
- **80% consumed**: Warning alert to SRE team
- **90% consumed**: Critical alert, freeze feature releases
- **100% consumed**: Emergency response, only critical fixes allowed

### Error Budget Dashboard

**Grafana Query:**
```promql
# Error budget remaining (minutes)
(
  (1 - (
    rate(controller_runtime_reconcile_errors_total{controller="permissionbinder"}[30d])
    /
    rate(controller_runtime_reconcile_total{controller="permissionbinder"}[30d])
  )) * 43200
) - 43
```

**Alert Rules:**
- See `example/monitoring/prometheus-alerts.yaml` → `PermissionBinderSLOViolation`
- See `example/monitoring/prometheus-alerts.yaml` → `PermissionBinderErrorBudgetWarning`

---

## Mean Time to Recovery (MTTR)

### MTTR Measurement

**Current MTTR:** Tracked via incident response logs

**Target MTTR:**
- **P1 (Critical)**: < 15 minutes
- **P2 (High)**: < 1 hour
- **P3 (Medium)**: < 4 hours
- **P4 (Low)**: < 24 hours

**MTTR Metrics:**
```promql
# Time from alert to resolution (requires incident tracking system)
# Currently tracked manually in incident reports
```

**MTTR Improvement:**
- Automated runbooks (see `docs/RUNBOOK.md`)
- Pre-configured remediation scripts
- Automated rollback procedures

---

## Mean Time Between Failures (MTBF)

### MTBF Measurement

**Current MTBF:** Calculated from incident frequency

**Target MTBF:**
- **P1 incidents**: > 30 days
- **P2 incidents**: > 7 days
- **P3 incidents**: > 1 day

**MTBF Metrics:**
```promql
# Time between reconciliation failures
# Requires incident tracking system integration
```

---

## Monitoring & Alerting

### Alert Hierarchy

**Tier 1 - Critical (Page on-call):**
- Operator down
- SLO violation (> 10 minutes)
- Error budget > 90% consumed
- Security breach

**Tier 2 - Warning (Notify team):**
- Slow reconciliation
- High error rate
- Error budget > 80% consumed
- Missing ClusterRoles

**Tier 3 - Info (Log only):**
- Orphaned resources detected
- ConfigMap processing delays
- Non-critical warnings

### Alert Rules

See:
- `example/monitoring/prometheus-alerts.yaml` - Prometheus alert rules
- `example/monitoring/loki-alerts.yaml` - Log-based alert rules
- `example/monitoring/prometheusrule.yaml` - PrometheusRule CRD

---

## Runbooks

### Incident Response

See `docs/RUNBOOK.md` for detailed incident response procedures:

- **P1 - Operator Down** (15 min SLA)
- **P2 - Reconciliation Failures** (1 hour SLA)
- **P3 - Slow Reconciliation** (4 hour SLA)
- **P4 - Warnings** (24 hour SLA)

### Common Procedures

1. **Operator Restart:**
   ```bash
   kubectl rollout restart deployment/operator-controller-manager -n permissions-binder-operator
   ```

2. **Emergency Rollback:**
   ```bash
   kubectl rollout undo deployment/operator-controller-manager -n permissions-binder-operator
   ```

3. **Revoke All Permissions:**
   ```bash
   kubectl delete rolebindings -A -l permission-binder.io/managed-by=permission-binder-operator
   ```

---

## Capacity Planning

### Resource Limits

**Current:**
- CPU: 100m request, 500m limit
- Memory: 128Mi request, 256Mi limit

**Scaling Guidelines:**
- **< 100 namespaces**: Current limits sufficient
- **100-500 namespaces**: Increase memory to 512Mi
- **> 500 namespaces**: Horizontal scaling (multiple replicas)

### Performance Benchmarks

**Reconciliation Performance:**
- **Single namespace**: < 1 second
- **10 namespaces**: < 5 seconds
- **100 namespaces**: < 30 seconds

**Memory Usage:**
- **Base**: ~50Mi
- **Per 100 namespaces**: +10Mi
- **Peak (reconciliation)**: +50Mi

---

## Postmortem Process

### Blameless Postmortem Template

**Incident Summary:**
- Date/Time
- Duration
- Impact
- Root Cause
- Resolution

**Timeline:**
- Detection
- Response
- Resolution
- Follow-up

**Action Items:**
- [ ] Short-term fixes
- [ ] Long-term improvements
- [ ] Process improvements
- [ ] Documentation updates

**Lessons Learned:**
- What went well
- What could be improved
- Prevention measures

---

## SRE Best Practices

### Toil Elimination

**Automated:**
- ✅ Operator deployment
- ✅ Monitoring & alerting
- ✅ Log aggregation
- ✅ Metrics collection

**To Be Automated:**
- [ ] Incident response (runbook automation)
- [ ] Capacity planning alerts
- [ ] Automated rollback on SLO violation
- [ ] Self-healing for common failures

### Reliability Patterns

**Implemented:**
- ✅ Retry with exponential backoff
- ✅ Circuit breaker (for external dependencies)
- ✅ Graceful degradation
- ✅ Orphaned resource adoption

**To Be Implemented:**
- [ ] Rate limiting for API calls
- [ ] Bulk operations optimization
- [ ] Caching for frequently accessed resources

---

## References

- **Monitoring Setup**: `example/monitoring/README.md`
- **Runbook**: `docs/RUNBOOK.md`
- **Grafana Dashboard**: `example/monitoring/grafana-dashboard.json`
- **Alert Rules**: `example/monitoring/prometheus-alerts.yaml`

---

## SLO Review Process

**Quarterly Review:**
1. Review SLO targets vs actual performance
2. Adjust SLOs if needed (with stakeholder approval)
3. Review error budget consumption
4. Update runbooks based on incidents
5. Review and optimize alerting rules

**Annual Review:**
1. Comprehensive SLO/SLI review
2. Capacity planning review
3. Disaster recovery drill
4. Postmortem analysis of all P1/P2 incidents
5. Update SRE documentation

