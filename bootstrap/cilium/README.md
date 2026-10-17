# Cilium on Talos

Cilium is bootstrapped by Talos, not Argo CD: Argo CD needs pod networking
before it can run. The generator renders the pinned Cilium Helm chart and
embeds it alongside Argo CD in `cluster.inlineManifests`.

- Chart version: `CILIUM_VERSION` in `scripts/gen-server-config.sh`.
- Cluster values: `bootstrap/cilium/<cluster-name>/values.yaml`.
- Server patch: `vps/vivid-koala/config.yaml` disables Flannel and kube-proxy.
- Rendered manifests and credentials stay in `clusters/<cluster-name>/.talos/`
  (ignored by Git).

The values use Kubernetes PodCIDR IPAM, Cilium kube-proxy replacement, Talos
KubePrism at `localhost:7445`, and Talos-compatible capabilities and cgroup
mounts. Legacy host routing preserves Talos host DNS forwarding. One operator
replica supports the single-node VPS. Routing otherwise uses the chart's
default VXLAN overlay; additional nodes need UDP 8472 permitted between them,
not exposed to the Internet.

## Fresh installation

```bash
mise install
mise run setup-server vivid-koala <server-ip> home
```

Talos applies Cilium once the Kubernetes API is available, allowing CoreDNS
and Argo CD to start. The configuration task checks Cilium and Argo CD rollouts.

For a cluster already using this Cilium bootstrap, apply values or chart
version changes with:

```bash
mise run conf-server vivid-koala home
```

Helm is only used to render YAML; there is no Helm release. Keep Cilium under
Talos management rather than independently installing it with Helm or Argo CD.
Follow Cilium's supported upgrade sequence when changing chart versions.

## Existing Flannel clusters

This is **not** an in-place migration procedure. Do not apply the new machine
configuration to an existing Flannel cluster without a migration plan or a
planned rebuild. Disabling Flannel and kube-proxy does not migrate existing
pods or clean up their networking state.

## Verify

```bash
export KUBECONFIG="$PWD/clusters/home/.talos/kubeconfig"
kubectl get nodes
kubectl get pods --namespace kube-system
kubectl exec --namespace kube-system ds/cilium -- cilium-dbg status
```

Reference: [Cilium's Talos installation guide](https://docs.cilium.io/en/stable/installation/k8s-install-helm/).
