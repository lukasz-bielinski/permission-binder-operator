# Monitoring Setup for Permission Binder Operator

This directory contains monitoring resources for the Permission Binder Operator.

## Files

- `servicemonitor.yaml` - ServiceMonitor for Prometheus Operator
- `prometheusrule.yaml` - PrometheusRule for alerting rules
- `grafana-dashboard.json` - Grafana dashboard configuration
- `prometheus-alerts.yaml` - Standalone Prometheus alerting rules
- `loki-alerts.yaml` - Loki log-based alerting rules

## Prerequisites

### Option 1: Prometheus Operator (Recommended)

If you have Prometheus Operator installed, use the ServiceMonitor and PrometheusRule:

```bash
kubectl apply -f servicemonitor.yaml
kubectl apply -f prometheusrule.yaml
```

### Option 2: Standalone Prometheus

If you don't have Prometheus Operator, use the standalone alerting rules:

```bash
# Add to your Prometheus configuration
kubectl apply -f prometheus-alerts.yaml
```

### Option 3: Manual Prometheus Configuration

Add this scrape configuration to your Prometheus config:

```yaml
scrape_configs:
- job_name: 'permission-binder-operator'
  kubernetes_sd_configs:
  - role: endpoints
    namespaces:
      names:
      - permissions-binder-operator
  relabel_configs:
  - source_labels: [__meta_kubernetes_service_name]
    action: keep
    regex: operator-controller-manager-metrics-service
  - source_labels: [__meta_kubernetes_endpoint_port_name]
    action: keep
    regex: https
  - source_labels: [__address__]
    target_label: __address__
    regex: (.+)
    replacement: ${1}:8443
  - source_labels: [__meta_kubernetes_namespace]
    target_label: kubernetes_namespace
  - source_labels: [__meta_kubernetes_service_name]
    target_label: kubernetes_service_name
  - source_labels: [__meta_kubernetes_pod_name]
    target_label: kubernetes_pod_name
  - source_labels: [__meta_kubernetes_pod_node_name]
    target_label: kubernetes_node_name
  scheme: https
  tls_config:
    insecure_skip_verify: true
  metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'permission_binder_.*'
    action: keep
```

## Metrics Available

The operator exposes the following custom metrics:

### Counters
- `permission_binder_missing_clusterrole_total` - Missing ClusterRole events (security critical)
- `permission_binder_adoption_events_total` - Orphaned resource adoption events
- `permission_binder_configmap_entries_processed_total` - ConfigMap processing (success/error/excluded)

### Gauges
- `permission_binder_orphaned_resources_total` - Current orphaned resources count
- `permission_binder_managed_rolebindings_total` - Current managed RoleBindings count
- `permission_binder_managed_namespaces_total` - Current managed namespaces count

## Alerting Rules

### Critical Alerts
- **PermissionBinderMissingClusterRole**: Missing ClusterRole detected (security risk)
- **PermissionBinderConfigMapProcessingFailed**: ConfigMap processing failures

### Warning Alerts
- **PermissionBinderHighOrphanedResources**: High number of orphaned resources
- **PermissionBinderLowConfigMapProcessingRate**: Low ConfigMap processing rate

### Info Alerts
- **PermissionBinderHighManagedResources**: High number of managed resources
- **PermissionBinderNoAdoptionEvents**: No recent adoption events

## Grafana Dashboard

Import the `grafana-dashboard.json` into your Grafana instance to get a comprehensive view of the operator's metrics and health.

## Log-based Monitoring

Use the `loki-alerts.yaml` rules with Grafana Loki for log-based alerting on:
- Security warnings
- Error patterns
- Performance issues
- Operational events

## Testing Metrics

To test if metrics are working:

```bash
# Port forward to metrics endpoint
kubectl port-forward -n permissions-binder-operator deployment/operator-controller-manager 8443:8443

# Check metrics
curl -k https://localhost:8443/metrics | grep permission_binder
```

## Troubleshooting

### Metrics Not Appearing

1. Check if the operator pod is running:
   ```bash
   kubectl get pods -n permissions-binder-operator
   ```

2. Check if the metrics service exists:
   ```bash
   kubectl get svc -n permissions-binder-operator
   ```

3. Test metrics endpoint directly:
   ```bash
   kubectl exec -n permissions-binder-operator deployment/operator-controller-manager -- wget -q -O- --no-check-certificate https://localhost:8443/metrics
   ```

### ServiceMonitor Not Working

1. Ensure Prometheus Operator is installed:
   ```bash
   kubectl get crd | grep monitoring
   ```

2. Check ServiceMonitor status:
   ```bash
   kubectl get servicemonitor -n permissions-binder-operator
   ```

3. Check Prometheus targets in the UI or:
   ```bash
   kubectl get prometheus -A
   ```

## Security Considerations

- Metrics endpoint uses HTTPS with self-signed certificates
- Consider network policies to restrict access to metrics port
- Monitor for unusual patterns in missing ClusterRole alerts
- Set up proper alerting for security-related metrics