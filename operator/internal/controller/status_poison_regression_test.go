package controller

// Manager-driven regression tests for the v1.8.0 status-poison fix.
//
// The shipped ginkgo suite only ever calls Reconcile() manually with a direct
// client; these tests run the REAL manager path instead - cached client,
// watch-driven reconciles and (on controller-runtime >= 0.23) the priority
// queue - which is where the wedge lived. Derived from the envtest repro that
// first proved the mechanism (parallel investigation session, 2026-08-24):
//
//	pass 1: full creation (ns+RB+SA+saRB) -> Status().Update FAILS transiently
//	        (injected "etcdserver: request timed out", as seen on a loaded
//	        rpi4-class apiserver)
//	pass 2: retry a few ms later -> informer cache does not yet see the
//	        namespace created in pass 1 (injected single stale NotFound) ->
//	        ensureNamespace Create => AlreadyExists
//
// PRE-fix behavior (reproduced): the AlreadyExists dropped the whitelist
// entry, ProcessedRoleBindings came out empty, the SA loop never ran, and the
// EMPTY lists were stamped with LastProcessedConfigMapVersion - the skip
// guard then wedged the CR permanently (only a ConfigMap RV bump healed it).
//
// POST-fix behavior (asserted here): the AlreadyExists falls through to the
// ownership/update path via the uncached APIReader re-read, the pass
// completes, and the status converges WITHOUT any ConfigMap bump. A
// Processed=False/ProcessingIncomplete condition may appear transiently on an
// incomplete pass but is timing-dependent, so it is not asserted.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/config"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logzap "sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	permissionv1 "github.com/permission-binder-operator/operator/api/v1"
)

const (
	poisonOpNS   = "pbo-poison-regression"
	poisonTestNS = "sa-test-34"
	poisonSAName = poisonTestNS + "-sa-status-test"
	poisonPBName = "test-sa-status-tracking"
)

// wedgeClient injects the reproduced failure sequence: one transient status
// write failure for the test PB, then ONE stale NotFound for the namespace
// created in pass 1 (models informer lag on a loaded cluster).
type wedgeClient struct {
	client.Client
	statusFailed  atomic.Bool
	staleNsServed atomic.Bool
}

func (w *wedgeClient) Status() client.SubResourceWriter {
	return &wedgeStatusWriter{w.Client.Status(), w}
}

func (w *wedgeClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	if _, isNS := obj.(*corev1.Namespace); isNS && key.Name == poisonTestNS &&
		w.statusFailed.Load() && w.staleNsServed.CompareAndSwap(false, true) {
		return apierrors.NewNotFound(schema.GroupResource{Resource: "namespaces"}, key.Name)
	}
	return w.Client.Get(ctx, key, obj, opts...)
}

type wedgeStatusWriter struct {
	client.SubResourceWriter
	p *wedgeClient
}

func (sw *wedgeStatusWriter) Update(ctx context.Context, obj client.Object, opts ...client.SubResourceUpdateOption) error {
	if pb, ok := obj.(*permissionv1.PermissionBinder); ok &&
		pb.Name == poisonPBName &&
		sw.p.statusFailed.CompareAndSwap(false, true) {
		return fmt.Errorf("injected transient apiserver failure: etcdserver: request timed out")
	}
	return sw.SubResourceWriter.Update(ctx, obj, opts...)
}

type poisonEnv struct {
	direct client.Client
	ctx    context.Context
}

// startPoisonEnv boots a dedicated envtest apiserver plus a REAL manager and
// registers the reconciler on it, optionally wrapping the manager client with
// a failure-injection decorator. Cleanup is registered on t.
func startPoisonEnv(t *testing.T, wrapClient func(client.Client) client.Client) *poisonEnv {
	t.Helper()
	ctrl.SetLogger(logzap.New(logzap.UseDevMode(false), logzap.WriteTo(os.Stdout)))

	env := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join("..", "..", "config", "crd", "bases")},
		ErrorIfCRDPathMissing: true,
		BinaryAssetsDirectory: filepath.Join("..", "..", "bin", "k8s",
			fmt.Sprintf("1.36.2-%s-%s", goruntime.GOOS, goruntime.GOARCH)),
	}
	cfg, err := env.Start()
	if err != nil {
		t.Fatalf("envtest start: %v", err)
	}
	t.Cleanup(func() { _ = env.Stop() })

	sch := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(sch); err != nil {
		t.Fatal(err)
	}
	if err := permissionv1.AddToScheme(sch); err != nil {
		t.Fatal(err)
	}

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 sch,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
		LeaderElection:         false,
		// Several tests in this file each build their own manager in the same
		// process; skip the global controller-name uniqueness check.
		Controller: config.Controller{SkipNameValidation: ptr.To(true)},
		Client: client.Options{
			Cache: &client.CacheOptions{
				DisableFor: []client.Object{&corev1.Secret{}},
			},
		},
	})
	if err != nil {
		t.Fatalf("manager: %v", err)
	}

	mgrClient := mgr.GetClient()
	if wrapClient != nil {
		mgrClient = wrapClient(mgrClient)
	}
	rec := &PermissionBinderReconciler{
		Client:    mgrClient,
		Scheme:    mgr.GetScheme(),
		APIReader: mgr.GetAPIReader(),
		DebugMode: true,
	}
	if err := rec.SetupWithManager(mgr); err != nil {
		t.Fatalf("setup: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = mgr.Start(ctx) }()
	if !mgr.GetCache().WaitForCacheSync(ctx) {
		t.Fatal("cache never synced")
	}

	// direct (uncached) client for test assertions, like kubectl in the e2e
	direct, err := client.New(cfg, client.Options{Scheme: sch})
	if err != nil {
		t.Fatal(err)
	}
	if err := direct.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: poisonOpNS}}); err != nil {
		t.Fatal(err)
	}

	return &poisonEnv{direct: direct, ctx: ctx}
}

// createTest34Fixtures mirrors example/tests/test-implementations/test-34-*.sh:
// CM sa-test-config-34 first, then the PB with a ServiceAccount mapping.
func createTest34Fixtures(t *testing.T, pe *poisonEnv) *corev1.ConfigMap {
	t.Helper()
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "sa-test-config-34", Namespace: poisonOpNS},
		Data: map[string]string{
			"whitelist.txt": "    CN=COMPANY-K8S-" + poisonTestNS + "-developer,OU=Groups,DC=example,DC=com",
		},
	}
	if err := pe.direct.Create(pe.ctx, cm); err != nil {
		t.Fatal(err)
	}
	pb := &permissionv1.PermissionBinder{
		ObjectMeta: metav1.ObjectMeta{Name: poisonPBName, Namespace: poisonOpNS},
		Spec: permissionv1.PermissionBinderSpec{
			ConfigMapName:         "sa-test-config-34",
			ConfigMapNamespace:    poisonOpNS,
			Prefixes:              []string{"COMPANY-K8S"},
			RoleMapping:           map[string]string{"developer": "edit"},
			ServiceAccountMapping: map[string]string{"status-test": "edit"},
		},
	}
	if err := pe.direct.Create(pe.ctx, pb); err != nil {
		t.Fatal(err)
	}
	return cm
}

func waitForPoison(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %s", what)
}

// assertStatusConverges polls like the e2e's 60s status assertion and fails
// the test when the entry never appears - the pre-fix wedge signature.
func assertStatusConverges(t *testing.T, pe *poisonEnv) {
	t.Helper()
	expected := poisonTestNS + "/" + poisonSAName
	var last permissionv1.PermissionBinder
	found := false
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if err := pe.direct.Get(pe.ctx, types.NamespacedName{Name: poisonPBName, Namespace: poisonOpNS}, &last); err == nil {
			for _, e := range last.Status.ProcessedServiceAccounts {
				if e == expected {
					found = true
				}
			}
			if found {
				break
			}
		}
		time.Sleep(2 * time.Second)
	}
	if !found {
		t.Fatalf("WEDGED (regression): status.processedServiceAccounts missing %q; status: RBs=%v SAs=%v cmVer=%q conds=%+v",
			expected, last.Status.ProcessedRoleBindings, last.Status.ProcessedServiceAccounts,
			last.Status.LastProcessedConfigMapVersion, last.Status.Conditions)
	}
	if last.Status.LastProcessedConfigMapVersion == "" {
		t.Error("converged status must carry the processed ConfigMap version")
	}
	processed := findCondition(last.Status.Conditions, "Processed")
	if processed == nil || processed.Status != metav1.ConditionTrue {
		t.Errorf("converged status must carry Processed=True, got: %+v", last.Status.Conditions)
	}
}

// TestManagerDrivenSAStatusTracking is the e2e test 34 happy path against the
// real manager (no failure injection) - guards the manager-driven code path
// the ginkgo suite never exercises.
func TestManagerDrivenSAStatusTracking(t *testing.T) {
	if testing.Short() {
		t.Skip("envtest-based, skipped in -short mode")
	}
	pe := startPoisonEnv(t, nil)
	createTest34Fixtures(t, pe)

	waitForPoison(t, 90*time.Second, "ServiceAccount "+poisonSAName, func() bool {
		return pe.direct.Get(pe.ctx, types.NamespacedName{Name: poisonSAName, Namespace: poisonTestNS}, &corev1.ServiceAccount{}) == nil
	})
	assertStatusConverges(t, pe)
}

// TestStatusPoisonWedgeRegression injects the exact reproduced wedge sequence
// (one transient status write failure + one stale namespace NotFound on the
// retry) and asserts the FIXED behavior: the entry recovers via the uncached
// AlreadyExists fall-through and the status converges WITHOUT any ConfigMap
// bump. Pre-fix, this test wedges: empty lists, stamped guard, no self-heal.
func TestStatusPoisonWedgeRegression(t *testing.T) {
	if testing.Short() {
		t.Skip("envtest-based, skipped in -short mode")
	}
	var wc *wedgeClient
	pe := startPoisonEnv(t, func(c client.Client) client.Client {
		wc = &wedgeClient{Client: c}
		return wc
	})
	createTest34Fixtures(t, pe)

	waitForPoison(t, 90*time.Second, "ServiceAccount "+poisonSAName, func() bool {
		return pe.direct.Get(pe.ctx, types.NamespacedName{Name: poisonSAName, Namespace: poisonTestNS}, &corev1.ServiceAccount{}) == nil
	})
	assertStatusConverges(t, pe)

	if !wc.statusFailed.Load() {
		t.Error("injection never fired - the test exercised nothing")
	}
	if !wc.staleNsServed.Load() {
		t.Log("note: stale-namespace injection did not fire (retry pass read a synced cache); status-failure half still validated")
	}
}
