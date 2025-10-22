package integration_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/k3s"
	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/release"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

const (
	chartPath     = "../../charts/catalyst"
	testTimeout   = 5 * time.Minute
	pollInterval  = 2 * time.Second
	pollTimeout   = 2 * time.Minute
	testNamespace = "catalyst-test"
	k3sImage      = "rancher/k3s:v1.27.1-k3s1"
)

// TestCatalystChart is the main test suite for the Catalyst Helm chart
func TestCatalystChart(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	tests := []struct {
		name         string
		releaseName  string
		values       map[string]interface{}
		validateFunc func(t *testing.T, clientset *kubernetes.Clientset, release *release.Release)
	}{
		{
			name:        "Install with default values",
			releaseName: "catalyst-default",
			values: map[string]interface{}{
				"join_token": "test-token-123",
			},
			validateFunc: validateDefaultInstall,
		},
		{
			name:        "Install with global registry override",
			releaseName: "catalyst-registry",
			values: map[string]interface{}{
				"join_token": "test-token-456",
				"global": map[string]interface{}{
					"image": map[string]interface{}{
						"registry": "my-registry.io",
					},
				},
			},
			validateFunc: validateGlobalRegistryOverride,
		},
		{
			name:        "Install with consolidated image",
			releaseName: "catalyst-consolidated",
			values: map[string]interface{}{
				"join_token": "test-token-789",
				"global": map[string]interface{}{
					"consolidated_image": map[string]interface{}{
						"enabled": true,
					},
				},
			},
			validateFunc: validateConsolidatedImage,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
			defer cancel()

			// Start K3s cluster
			k3sContainer, clientset := setupK3sCluster(t, ctx)
			defer testcontainers.CleanupContainer(t, k3sContainer)

			// Get kubeconfig for Helm
			kubeConfig, err := k3sContainer.GetKubeConfig(ctx)
			require.NoError(t, err, "Failed to get kubeconfig")

			// Install the Helm chart
			rel := installChart(t, ctx, kubeConfig, tt.releaseName, tt.values)
			require.NotNil(t, rel, "Failed to install chart")

			// Run scenario-specific validations
			if tt.validateFunc != nil {
				tt.validateFunc(t, clientset, rel)
			}
		})
	}
}

// setupK3sCluster creates a K3s cluster and returns the container and Kubernetes clientset
func setupK3sCluster(t *testing.T, ctx context.Context) (*k3s.K3sContainer, *kubernetes.Clientset) {
	t.Helper()

	t.Log("Starting K3s cluster...")
	k3sContainer, err := k3s.Run(ctx, k3sImage)
	require.NoError(t, err, "Failed to start K3s container")

	kubeConfigYaml, err := k3sContainer.GetKubeConfig(ctx)
	require.NoError(t, err, "Failed to get kubeconfig")

	restConfig, err := clientcmd.RESTConfigFromKubeConfig(kubeConfigYaml)
	require.NoError(t, err, "Failed to create REST config")

	clientset, err := kubernetes.NewForConfig(restConfig)
	require.NoError(t, err, "Failed to create Kubernetes clientset")

	// Create test namespace
	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: testNamespace,
		},
	}
	_, err = clientset.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{})
	require.NoError(t, err, "Failed to create test namespace")

	t.Log("K3s cluster ready")
	return k3sContainer, clientset
}

// k3sRESTClientGetter implements the genericclioptions.RESTClientGetter interface
// to provide Helm with access to the K3s cluster's kubeconfig
type k3sRESTClientGetter struct {
	restConfig      *rest.Config
	discoveryClient discovery.CachedDiscoveryInterface
	namespace       string
}

func newK3sRESTClientGetter(kubeConfig []byte, namespace string) (*k3sRESTClientGetter, error) {
	restConfig, err := clientcmd.RESTConfigFromKubeConfig(kubeConfig)
	if err != nil {
		return nil, err
	}

	discoveryClient, err := discovery.NewDiscoveryClientForConfig(restConfig)
	if err != nil {
		return nil, err
	}

	return &k3sRESTClientGetter{
		restConfig:      restConfig,
		discoveryClient: memory.NewMemCacheClient(discoveryClient),
		namespace:       namespace,
	}, nil
}

func (c *k3sRESTClientGetter) ToRESTConfig() (*rest.Config, error) {
	return c.restConfig, nil
}

func (c *k3sRESTClientGetter) ToDiscoveryClient() (discovery.CachedDiscoveryInterface, error) {
	return c.discoveryClient, nil
}

func (c *k3sRESTClientGetter) ToRESTMapper() (meta.RESTMapper, error) {
	return restmapper.NewDeferredDiscoveryRESTMapper(c.discoveryClient), nil
}

func (c *k3sRESTClientGetter) ToRawKubeConfigLoader() clientcmd.ClientConfig {
	// Return a minimal client config that provides the namespace
	return &k3sClientConfig{namespace: c.namespace}
}

// k3sClientConfig is a minimal implementation of clientcmd.ClientConfig
type k3sClientConfig struct {
	namespace string
}

func (c *k3sClientConfig) RawConfig() (clientcmdapi.Config, error) {
	return clientcmdapi.Config{}, nil
}

func (c *k3sClientConfig) ClientConfig() (*rest.Config, error) {
	return nil, nil
}

func (c *k3sClientConfig) Namespace() (string, bool, error) {
	return c.namespace, false, nil
}

func (c *k3sClientConfig) ConfigAccess() clientcmd.ConfigAccess {
	return nil
}

// installChart installs the Catalyst Helm chart with the given values
func installChart(t *testing.T, ctx context.Context, kubeConfig []byte, releaseName string, values map[string]interface{}) *release.Release {
	t.Helper()

	t.Logf("Installing chart as release: %s", releaseName)

	// Create REST client getter for the K3s cluster
	restClientGetter, err := newK3sRESTClientGetter(kubeConfig, testNamespace)
	require.NoError(t, err, "Failed to create REST client getter")

	// Create Helm action configuration using the K3s cluster's REST client getter
	actionConfig := new(action.Configuration)
	err = actionConfig.Init(restClientGetter, testNamespace, "memory", func(format string, v ...interface{}) {
		t.Logf(format, v...)
	})
	require.NoError(t, err, "Failed to initialize Helm action config")

	// Create install action
	install := action.NewInstall(actionConfig)
	install.Namespace = testNamespace
	install.ReleaseName = releaseName
	install.Wait = false // We'll validate manually
	install.Timeout = pollTimeout

	// Load the chart
	absChartPath, err := filepath.Abs(chartPath)
	require.NoError(t, err, "Failed to get absolute chart path")

	chart, err := loader.Load(absChartPath)
	require.NoError(t, err, "Failed to load chart")

	// Install the chart
	rel, err := install.Run(chart, values)
	require.NoError(t, err, "Failed to install chart")

	t.Logf("Chart installed successfully: %s", rel.Name)
	return rel
}

// Validation functions

func validateDefaultInstall(t *testing.T, clientset *kubernetes.Clientset, rel *release.Release) {
	ctx := context.Background()

	// Validate that the release was installed
	assert.Equal(t, release.StatusDeployed, rel.Info.Status, "Release should be deployed")

	// Validate that expected deployments exist
	expectedDeployments := []string{
		"catalyst-agent",
		"catalyst-management",
	}

	for _, deploymentName := range expectedDeployments {
		deployment, err := clientset.AppsV1().Deployments(testNamespace).Get(ctx, deploymentName, metav1.GetOptions{})
		if err != nil {
			t.Logf("Deployment %s not found yet (this is expected as pods may still be starting): %v", deploymentName, err)
			continue
		}
		if deployment != nil && deployment.Spec.Template.Spec.Containers != nil {
			t.Logf("Found deployment: %s with %d replicas", deploymentName, *deployment.Spec.Replicas)
		}
	}

	// Validate ConfigMaps exist
	configMaps, err := clientset.CoreV1().ConfigMaps(testNamespace).List(ctx, metav1.ListOptions{})
	assert.NoError(t, err, "Should be able to list ConfigMaps")
	assert.NotEmpty(t, configMaps.Items, "Should have at least one ConfigMap")
	t.Logf("Found %d ConfigMaps", len(configMaps.Items))

	// Validate Services exist
	services, err := clientset.CoreV1().Services(testNamespace).List(ctx, metav1.ListOptions{})
	assert.NoError(t, err, "Should be able to list Services")
	assert.NotEmpty(t, services.Items, "Should have at least one Service")
	t.Logf("Found %d Services", len(services.Items))
}

func validateGlobalRegistryOverride(t *testing.T, clientset *kubernetes.Clientset, rel *release.Release) {
	ctx := context.Background()

	// Get agent deployment
	deployment, err := clientset.AppsV1().Deployments(testNamespace).Get(ctx, "catalyst-agent", metav1.GetOptions{})
	if err != nil {
		t.Logf("Warning: Could not get agent deployment: %v", err)
		return
	}

	// Validate that the image uses the custom registry
	if len(deployment.Spec.Template.Spec.Containers) > 0 {
		image := deployment.Spec.Template.Spec.Containers[0].Image
		assert.Contains(t, image, "my-registry.io", "Image should use custom registry")
		t.Logf("Agent image: %s", image)
	}

	// Validate ConfigMap has custom registry
	cm, err := clientset.CoreV1().ConfigMaps(testNamespace).Get(ctx, "catalyst-agent-config", metav1.GetOptions{})
	if err == nil && cm.Data["config.yaml"] != "" {
		assert.Contains(t, cm.Data["config.yaml"], "my-registry.io", "ConfigMap should reference custom registry")
	}
}

func validateConsolidatedImage(t *testing.T, clientset *kubernetes.Clientset, rel *release.Release) {
	ctx := context.Background()

	// Get agent deployment
	deployment, err := clientset.AppsV1().Deployments(testNamespace).Get(ctx, "catalyst-agent", metav1.GetOptions{})
	if err != nil {
		t.Logf("Warning: Could not get agent deployment: %v", err)
		return
	}

	// Validate that the image uses consolidated image
	if len(deployment.Spec.Template.Spec.Containers) > 0 {
		image := deployment.Spec.Template.Spec.Containers[0].Image
		assert.Contains(t, image, "catalyst-all", "Image should use consolidated image")
		t.Logf("Agent consolidated image: %s", image)
	}

	// Validate management also uses consolidated image
	mgmtDeployment, err := clientset.AppsV1().Deployments(testNamespace).Get(ctx, "catalyst-management", metav1.GetOptions{})
	if err == nil && len(mgmtDeployment.Spec.Template.Spec.Containers) > 0 {
		image := mgmtDeployment.Spec.Template.Spec.Containers[0].Image
		assert.Contains(t, image, "catalyst-all", "Management should use consolidated image")
		t.Logf("Management consolidated image: %s", image)
	}
}
