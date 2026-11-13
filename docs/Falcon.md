# Falcon operations

Flint uses the installed native `kubectl.exe`, the existing kubeconfig and its authentication provider. SAW access normally requires kubelogin and active JIT permissions. ARM authentication alone does not establish Kubernetes access. Report authentication or RBAC failures with the exact context and namespace; let the user complete the existing SAW authentication/JIT process.

## Locate the target

1. Establish the environment/region, namespace and application name from the request or previous results. Ask for missing scope rather than guessing.
2. Use `kubectl config get-contexts` to discover configured context names. Specify `--context` on every cluster request and `--namespace` for namespaced resources. Do not change the global current context.
3. Use `kubectl api-resources --context <context> --api-group <group>` and `kubectl explain <resource>.spec --context <context> --api-version <group>/v1alpha1` to check the installed resource names and fields. Application uses `apis.clusterfleet.io`; CrossClusterDataDeployment uses `data.falcon.io`. Confirm the served version through discovery.

The Control Cluster (CC) contains Application and CrossClusterDataDeployment resources. The scheduler distributes Application workloads to Standard Clusters (SCs) through ManifestWorks. SCs run the actual Deployments and Pods. Applications can span several SCs, and SCs are ephemeral; discover placement from the current application, ManifestWork and Fleet resource data instead of deriving it from a cluster name.

FleetPod, FleetDeployment and FleetNode objects report SC resources into the CC, commonly in a namespace such as `std-cluster-sc-<region>-<id>`. This namespace may differ from the original application namespace and require separate RBAC access. A CC's ordinary Pods are not a fleet-wide workload listing. Use the actual API resource names and metadata returned by the cluster to locate the SC and original resource.

## Read state

Use the existing `run_command` tool with `executor="kubectl"` and separate literal argument tokens. These examples use placeholders, not configured cluster names:

```text
kubectl get applications.apis.clusterfleet.io <app> --context <cc-context> --namespace <namespace> --output json
kubectl get crossclusterdatadeployments.data.falcon.io <deployment> --context <cc-context> --namespace <namespace> --output json
kubectl get fleetpods --context <cc-context> --namespace <sc-report-namespace> --output json
kubectl get pods --context <sc-context> --namespace <namespace> --selector app.kubernetes.io/instance=<instance> --output json
kubectl get events --context <sc-context> --namespace <namespace> --field-selector involvedObject.name=<pod> --output json
kubectl describe pods <pod> --context <sc-context> --namespace <namespace>
```

Read selectors from the actual application/workload metadata; do not assume every app uses the example label. Use narrow queries and named resources. Independent reads can run together; CC-to-SC discovery requires the previous result first.

Nonempty command output is saved after the existing redaction. `result_path` contains stdout, or stderr when stdout is empty. `stderr_result_path` contains separate stderr when both streams exist. Use `read_file` and `search_text` for saved output. `preview_truncated` applies to the preview; `capture_incomplete` means the process capture itself stopped early and the saved data can be partial. The process output limit remains 1 MiB. Narrow an oversized query; `--chunk-size` alone does not bound kubectl's final combined output. `item_count` counts only saved items; a nonempty `next_continue` means a Kubernetes list is incomplete.

Inspect conditions, their reasons/messages, and the actual workload state. For data deployment, compare target version, `lastKnownGoodVersion`, available/updated/unsuccessful Pods, `status.clusters` and any debug observations. A stopped `Progressing` condition can mean paused or no matching Pods, so read its reason.

## Change desired state

`spec` describes desired configuration; controllers maintain `status`. Read the current object before constructing a change. For Application replica changes, find the `spec.workload[]` entry whose `manifest.kind` is `Deployment` and whose `manifest.metadata.name` matches the requested workload. Its replica count is at `spec.workload[index].manifest.spec.replicas`. Do not assume index 0 or a top-level Application `spec.replicas`.

For Application and CrossClusterDataDeployment, use a named-resource `kubectl patch` with explicit `--context`, `--namespace`, `--type=json` and inline `--patch`. Flint requires the first JSON Patch operation to test the resourceVersion read from the object, followed by operations below `/spec/`. For example, after resolving the actual array index, manifest name and version:

```json
[
  { "op": "test", "path": "/metadata/resourceVersion", "value": "<observed-version>" },
  { "op": "test", "path": "/spec/workload/0/manifest/kind", "value": "Deployment" },
  { "op": "test", "path": "/spec/workload/0/manifest/metadata/name", "value": "<deployment-name>" },
  { "op": "replace", "path": "/spec/workload/0/manifest/spec/replicas", "value": 6 }
]
```

Use `add` if the intended field is absent. Put the exact target and old-to-new values in `purpose`, in the user's language. Flint shows the invocation for approval and runs writes sequentially without automatic retry. A resourceVersion conflict requires a fresh read and a newly reviewed patch.

Change the CC Application for persistent desired workload configuration. Direct SC changes can be reconciled by Falcon. Runtime repairs such as deleting a particular Pod require a specific user request, a confirmed SC target and approval. Fleet mirror deletion is consequential: the Cleaner can delete the corresponding real resource. Do not use Fleet mirror edits as a shortcut for changing workload configuration. Node repair is handled by Falcon DRI. Keep persistent source manifests/release configuration aligned when the user requests a lasting configuration change.

## Verify the outcome

Exit code 0 confirms command completion, not rollout completion. Read the updated CC resource and, where needed, the relevant SC resources. Compare the intended spec, controller conditions, `observedGeneration` when provided, and actual ready replicas across the placements. Report pending if convergence has not completed within the available time; never repeat a patch to check progress. After a timeout, connection loss or cancellation, inspect actual state before any new mutation.

Reference: FalconDocs Fleet Architecture, Application, Data Deployments, StandardCluster Syncer and JIT guides. Installed CRD schemas and current resource objects determine the exact supported fields. The optional kubectl-fleet plugin has version-dependent commands; check its installed help before proposing plugin-specific operations.
