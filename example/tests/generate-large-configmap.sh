#!/bin/bash
# Generate large ConfigMap for scale testing
# Creates ConfigMap with 100+ entries

cat <<EOF > large-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: permission-config-large
  namespace: permissions-binder-operator
  labels:
    app.kubernetes.io/name: permission-binder-operator
    test-type: large-scale
data:
EOF

# Generate 100 namespace entries
for i in {1..100}; do
  echo "  NEW_PREFIX-ns$(printf "%03d" $i)-project-admin: \"NEW_PREFIX-ns$(printf "%03d" $i)-project-admin\"" >> large-configmap.yaml
  echo "  NEW_PREFIX-ns$(printf "%03d" $i)-project-engineer: \"NEW_PREFIX-ns$(printf "%03d" $i)-project-engineer\"" >> large-configmap.yaml
  echo "  NEW_PREFIX-ns$(printf "%03d" $i)-project-viewer: \"NEW_PREFIX-ns$(printf "%03d" $i)-project-viewer\"" >> large-configmap.yaml
done

echo "Generated large-configmap.yaml with 300 entries (100 namespaces x 3 roles)"
echo "Size: $(wc -c < large-configmap.yaml) bytes"
echo ""
echo "To apply:"
echo "  kubectl apply -f large-configmap.yaml"
echo ""
echo "To update PermissionBinder:"
echo "  kubectl patch permissionbinder permissionbinder-example -n permissions-binder-operator \\"
echo "    --type=merge -p '{\"spec\":{\"configMapName\":\"permission-config-large\"}}'"

