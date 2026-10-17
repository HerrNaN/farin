#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <server-name> <cluster-name>" >&2
    exit 1
fi

SERVER_NAME=$1
CLUSTER_NAME=$2
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SERVER_DIR="$ROOT_DIR/vps/$SERVER_NAME"
CLUSTER_DIR="$ROOT_DIR/clusters/$CLUSTER_NAME"

if [[ "$SERVER_NAME" == */* ]] || [ "$SERVER_NAME" = "." ] || [ "$SERVER_NAME" = ".." ]; then
    echo "Invalid server name: $SERVER_NAME" >&2
    exit 1
fi

if [[ "$CLUSTER_NAME" == */* ]] || [ "$CLUSTER_NAME" = "." ] || [ "$CLUSTER_NAME" = ".." ]; then
    echo "Invalid cluster name: $CLUSTER_NAME" >&2
    exit 1
fi

if [ ! -f "$SERVER_DIR/config.yaml" ]; then
    echo "Server configuration not found: $SERVER_DIR/config.yaml" >&2
    exit 1
fi

umask 077

TALOS_DIR="$CLUSTER_DIR/.talos"
SECRETS_FILE="$TALOS_DIR/secrets.yaml"
TALOSCONFIG_FILE="$TALOS_DIR/talosconfig"
CONTROLPLANE_FILE="$TALOS_DIR/controlplane.yaml"
KUBECONFIG_FILE="$TALOS_DIR/kubeconfig"

if [ ! -f "$SECRETS_FILE" ] || [ ! -f "$TALOSCONFIG_FILE" ]; then
    echo "Talos credentials are missing; run 'mise run setup-server $SERVER_NAME <server-ip> $CLUSTER_NAME' first" >&2
    exit 1
fi

export TALOSCONFIG="$TALOSCONFIG_FILE"
SERVER_NODE=$(talosctl config info --output json | jq -er '.nodes[0] // .endpoints[0]')
SERVER_HOST=${SERVER_NODE#https://}
SERVER_HOST=${SERVER_HOST#http://}
SERVER_HOST=${SERVER_HOST%/}

bash "$ROOT_DIR/scripts/gen-server-config.sh" "$SERVER_NAME" "$SERVER_HOST" "$CLUSTER_NAME"
export TALOSCONFIG="$TALOSCONFIG_FILE"

echo "> applying machine config"
talosctl apply-config \
    --nodes "$SERVER_NODE" \
    --file "$CONTROLPLANE_FILE"

echo "> talosctl health"
talosctl health --nodes "$SERVER_NODE" --wait-timeout 20m

echo "> talosctl kubeconfig"
talosctl kubeconfig "$KUBECONFIG_FILE" \
    --nodes "$SERVER_NODE" \
    --merge=false \
    --force
chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

echo "> waiting for Cilium"
kubectl rollout status daemonset/cilium --namespace kube-system --timeout=10m
kubectl rollout status deployment/cilium-operator --namespace kube-system --timeout=10m

echo "> waiting for Argo CD"
kubectl wait --for=create deployment/argocd-server --namespace argocd --timeout=10m
kubectl rollout status deployment --all --namespace argocd --timeout=10m
kubectl rollout status statefulset/argocd-application-controller --namespace argocd --timeout=10m
