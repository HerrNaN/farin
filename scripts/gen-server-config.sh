#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <server-name> <server-ip> <cluster-name>" >&2
    exit 1
fi

SERVER_NAME=$1
SERVER_IP=$2
CLUSTER_NAME=$3
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SERVER_DIR="$ROOT_DIR/vps/$SERVER_NAME"
CLUSTER_DIR="$ROOT_DIR/clusters/$CLUSTER_NAME"
TALOS_DIR="$CLUSTER_DIR/.talos"
SECRETS_FILE="$TALOS_DIR/secrets.yaml"
TALOSCONFIG_FILE="$TALOS_DIR/talosconfig"
CONTROLPLANE_FILE="$TALOS_DIR/controlplane.yaml"
ARGOCD_DIR="$ROOT_DIR/bootstrap/argocd/$CLUSTER_NAME"
ARGOCD_MANIFEST_FILE="$TALOS_DIR/argocd.yaml"
CLUSTER_PATCH_FILE="$TALOS_DIR/cluster-patch.json"

if [ ! -f "$SERVER_DIR/config.yaml" ]; then
    echo "Server configuration not found: $SERVER_DIR/config.yaml" >&2
    exit 1
fi

if [ ! -f "$CLUSTER_DIR/applications/kustomization.yaml" ]; then
    echo "Cluster configuration not found: $CLUSTER_DIR/applications/kustomization.yaml" >&2
    exit 1
fi

if [ ! -f "$ARGOCD_DIR/kustomization.yaml" ]; then
    echo "Argo CD bootstrap configuration not found: $ARGOCD_DIR/kustomization.yaml" >&2
    exit 1
fi

if [ ! -f "$SECRETS_FILE" ]; then
    echo "Talos secrets not found: $SECRETS_FILE" >&2
    exit 1
fi

umask 077

echo "> rendering Argo CD bootstrap manifests"
kubectl kustomize "$ARGOCD_DIR" > "$ARGOCD_MANIFEST_FILE"
jq --null-input \
    --rawfile manifest "$ARGOCD_MANIFEST_FILE" \
    '{cluster: {inlineManifests: [{name: "argocd", contents: $manifest}]}}' \
    > "$CLUSTER_PATCH_FILE"

echo "> talosctl gen config"
talosctl gen config "$CLUSTER_NAME" "https://$SERVER_IP:6443" \
    --with-secrets "$SECRETS_FILE" \
    --config-patch "@$SERVER_DIR/config.yaml" \
    --config-patch "@$CLUSTER_PATCH_FILE" \
    --output-types controlplane,talosconfig \
    --output "$TALOS_DIR" \
    --force

chmod 600 \
    "$SECRETS_FILE" \
    "$TALOSCONFIG_FILE" \
    "$CONTROLPLANE_FILE" \
    "$ARGOCD_MANIFEST_FILE" \
    "$CLUSTER_PATCH_FILE"

export TALOSCONFIG="$TALOSCONFIG_FILE"
talosctl config endpoints "$SERVER_IP"
talosctl config node "$SERVER_IP"
