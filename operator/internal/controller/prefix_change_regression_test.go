package controller

// Regression test for issue #94: a prefix-only spec change was a no-op.
//
// Changing spec.prefixes (ConfigMap and spec.roleMapping untouched) passed the
// generation-bump predicate, but the skip guard in Reconcile compared only the
// ConfigMap resourceVersion and the roleMapping hash, so the event was dropped
// with "ConfigMap and role mapping have not changed, skipping reconciliation":
// the old-prefix RoleBindings survived, the new-prefix entries were never
// processed, and the Processed condition kept the stale observedGeneration
// until the next ConfigMap or roleMapping change.
//
// POST-fix behavior (asserted here, manual Reconcile() calls against the shared
// envtest apiserver like the rest of the ginkgo suite):
//
//	pass 1: prefixes [OLD-PFX] -> RoleBinding pfxtest-old/pfxtest-old-admin,
//	        status.lastProcessedGeneration stamped, the NEW-PFX whitelist entry
//	        is inert (namespace pfxtest-new never created)
//	pass 2: nothing changed -> skip path, status resourceVersion untouched
//	pass 3: prefixes [NEW-PFX] only -> reconcileAllManagedResources deletes the
//	        old-prefix RoleBinding, processConfigMap creates the new one, the
//	        generation and observedGeneration advance, the ConfigMap version
//	        stays the same (no ConfigMap edit was involved)
//
// envtest runs no namespace controller, so namespaces are never deleted here -
// every name is unique to this test.

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

const (
	pfxOpNS   = "pbo-prefix-change"
	pfxCMName = "permission-config-prefix"
	pfxPBName = "prefix-change-test"
	pfxOldNS  = "pfxtest-old"
	pfxNewNS  = "pfxtest-new"
	pfxOldRB  = pfxOldNS + "-admin"
	pfxNewRB  = pfxNewNS + "-admin"
)

var _ = Describe("PermissionBinder prefix change (issue #94 regression)", func() {
	It("reprocesses a prefix-only spec change against the unchanged ConfigMap", func() {
		reconciler := &PermissionBinderReconciler{
			Client: k8sClient,
			Scheme: k8sClient.Scheme(),
		}
		pbKey := types.NamespacedName{Name: pfxPBName, Namespace: pfxOpNS}
		cmKey := types.NamespacedName{Name: pfxCMName, Namespace: pfxOpNS}
		oldRBKey := types.NamespacedName{Name: pfxOldRB, Namespace: pfxOldNS}
		newRBKey := types.NamespacedName{Name: pfxNewRB, Namespace: pfxNewNS}
		req := reconcile.Request{NamespacedName: pbKey}

		By("creating the operator namespace, the ConfigMap and the PermissionBinder")
		Expect(k8sClient.Create(ctx, &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{Name: pfxOpNS},
		})).To(Succeed())
		Expect(k8sClient.Create(ctx, &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: pfxCMName, Namespace: pfxOpNS},
			Data: map[string]string{
				"whitelist.txt": "CN=OLD-PFX-" + pfxOldNS + "-admin,OU=Groups,DC=example,DC=com\n" +
					"CN=NEW-PFX-" + pfxNewNS + "-admin,OU=Groups,DC=example,DC=com\n",
			},
		})).To(Succeed())
		Expect(k8sClient.Create(ctx, &permissionv1.PermissionBinder{
			ObjectMeta: metav1.ObjectMeta{Name: pfxPBName, Namespace: pfxOpNS},
			Spec: permissionv1.PermissionBinderSpec{
				Prefixes:           []string{"OLD-PFX"},
				RoleMapping:        map[string]string{"admin": "admin"},
				ConfigMapName:      pfxCMName,
				ConfigMapNamespace: pfxOpNS,
			},
		})).To(Succeed())

		By("reconciling twice: the first call only adds the finalizer")
		for i := 0; i < 2; i++ {
			_, err := reconciler.Reconcile(ctx, req)
			Expect(err).NotTo(HaveOccurred())
		}

		By("asserting the OLD-PFX pass: RoleBinding, status and condition")
		var cm corev1.ConfigMap
		Expect(k8sClient.Get(ctx, cmKey, &cm)).To(Succeed())
		var pb permissionv1.PermissionBinder
		Expect(k8sClient.Get(ctx, pbKey, &pb)).To(Succeed())
		genBefore := pb.Generation
		Expect(pb.Status.LastProcessedGeneration).To(Equal(genBefore))
		Expect(pb.Status.LastProcessedConfigMapVersion).To(Equal(cm.ResourceVersion))
		Expect(pb.Status.ProcessedRoleBindings).To(Equal([]string{pfxOldNS + "/" + pfxOldRB}))
		processed := findCondition(pb.Status.Conditions, "Processed")
		Expect(processed).NotTo(BeNil())
		Expect(processed.Status).To(Equal(metav1.ConditionTrue))
		Expect(processed.ObservedGeneration).To(Equal(genBefore))

		var rb rbacv1.RoleBinding
		Expect(k8sClient.Get(ctx, oldRBKey, &rb)).To(Succeed())
		Expect(rb.Subjects).To(HaveLen(1))
		Expect(rb.Subjects[0].Kind).To(Equal("Group"))
		Expect(rb.Subjects[0].Name).To(Equal("OLD-PFX-" + pfxOldNS + "-admin"))
		err := k8sClient.Get(ctx, types.NamespacedName{Name: pfxNewNS}, &corev1.Namespace{})
		Expect(apierrors.IsNotFound(err)).To(BeTrue(),
			"namespace %s must not exist: the NEW-PFX entry is inert under prefixes [OLD-PFX]", pfxNewNS)

		By("reconciling with nothing changed: the skip path must leave the status untouched")
		rvBefore := pb.ResourceVersion
		_, err = reconciler.Reconcile(ctx, req)
		Expect(err).NotTo(HaveOccurred())
		Expect(k8sClient.Get(ctx, pbKey, &pb)).To(Succeed())
		Expect(pb.ResourceVersion).To(Equal(rvBefore))

		By("changing spec.prefixes only (ConfigMap and roleMapping untouched)")
		pb.Spec.Prefixes = []string{"NEW-PFX"}
		Expect(k8sClient.Update(ctx, &pb)).To(Succeed())
		Expect(k8sClient.Get(ctx, pbKey, &pb)).To(Succeed())
		genAfter := pb.Generation
		Expect(genAfter).To(BeNumerically(">", genBefore))

		_, err = reconciler.Reconcile(ctx, req)
		Expect(err).NotTo(HaveOccurred())

		By("asserting the NEW-PFX pass: old RoleBinding deleted, new one created")
		err = k8sClient.Get(ctx, oldRBKey, &rb)
		Expect(apierrors.IsNotFound(err)).To(BeTrue(),
			"RoleBinding %s/%s must be deleted by the prefix cleanup (regression of issue #94)", pfxOldNS, pfxOldRB)
		Expect(k8sClient.Get(ctx, newRBKey, &rb)).To(Succeed())
		Expect(rb.Subjects).To(HaveLen(1))
		Expect(rb.Subjects[0].Kind).To(Equal("Group"))
		Expect(rb.Subjects[0].Name).To(Equal("NEW-PFX-" + pfxNewNS + "-admin"))

		Expect(k8sClient.Get(ctx, pbKey, &pb)).To(Succeed())
		Expect(pb.Status.LastProcessedGeneration).To(Equal(genAfter))
		processed = findCondition(pb.Status.Conditions, "Processed")
		Expect(processed).NotTo(BeNil())
		Expect(processed.Status).To(Equal(metav1.ConditionTrue))
		Expect(processed.ObservedGeneration).To(Equal(genAfter))
		Expect(pb.Status.LastProcessedConfigMapVersion).To(Equal(cm.ResourceVersion),
			"no ConfigMap change was involved, the processed version must not move")
		Expect(pb.Status.ProcessedRoleBindings).To(Equal([]string{pfxNewNS + "/" + pfxNewRB}))

		By("cleaning up: delete the CR, run the finalizer (SAFE-MODE orphaning), delete the ConfigMap")
		Expect(k8sClient.Delete(ctx, &pb)).To(Succeed())
		_, err = reconciler.Reconcile(ctx, req)
		Expect(err).NotTo(HaveOccurred())
		err = k8sClient.Get(ctx, pbKey, &pb)
		Expect(apierrors.IsNotFound(err)).To(BeTrue(), "finalizer must be removed so the CR is gone")
		Expect(k8sClient.Delete(ctx, &cm)).To(Succeed())
	})
})
