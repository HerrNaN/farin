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

if [ ! -f "$CLUSTER_DIR/applications/kustomization.yaml" ]; then
    echo "Cluster configuration not found: $CLUSTER_DIR/applications/kustomization.yaml" >&2
    exit 1
fi

umask 077

TALOS_DIR="$CLUSTER_DIR/.talos"
SECRETS_FILE="$TALOS_DIR/secrets.yaml"
TALOSCONFIG_FILE="$TALOS_DIR/talosconfig"
CONTROLPLANE_FILE="$TALOS_DIR/controlplane.yaml"

mkdir -p "$TALOS_DIR"

LEGACY_SECRETS_FILE="$SERVER_DIR/.talos/secrets.yaml"
if [ ! -e "$SECRETS_FILE" ] && [ -f "$LEGACY_SECRETS_FILE" ]; then
    echo "> migrating Talos secrets from the server to cluster $CLUSTER_NAME"
    mv "$LEGACY_SECRETS_FILE" "$SECRETS_FILE"
fi

if [ -f "$SECRETS_FILE" ]; then
    echo "> reusing $SECRETS_FILE"
elif [ -e "$CONTROLPLANE_FILE" ] || [ -e "$TALOSCONFIG_FILE" ]; then
    echo "Refusing to generate new secrets while existing cluster files are present" >&2
    echo "Restore $SECRETS_FILE or remove the entire $TALOS_DIR directory" >&2
    exit 1
else
    echo "> talosctl gen secrets"
    talosctl gen secrets --output-file "$SECRETS_FILE"
fi

bash "$ROOT_DIR/scripts/gen-server-config.sh" "$SERVER_NAME" "$SERVER_IP" "$CLUSTER_NAME"

export TALOSCONFIG="$TALOSCONFIG_FILE"

if timeout 10s talosctl get machineconfig \
    --nodes "$SERVER_IP" \
    --endpoints "$SERVER_IP" >/dev/null 2>&1
then
    if talosctl service etcd --nodes "$SERVER_IP" 2>/dev/null | grep -q "Running pre state"; then
        echo "> resuming setup before etcd bootstrap"
    else
        echo "Talos is already bootstrapped; use 'mise run conf-server $SERVER_NAME $CLUSTER_NAME'" >&2
        exit 1
    fi

    echo "> applying initial machine config"
    talosctl apply-config \
        --nodes "$SERVER_IP" \
        --file "$CONTROLPLANE_FILE"
elif timeout 10s talosctl version \
    --nodes "$SERVER_IP" \
    --endpoints "$SERVER_IP" \
    --insecure >/dev/null 2>&1
then
    echo "> applying initial machine config"
    talosctl apply-config \
        --insecure \
        --nodes "$SERVER_IP" \
        --file "$CONTROLPLANE_FILE"

    echo "> waiting for etcd bootstrap readiness"
    if ! timeout 10m bash -c \
        'until talosctl service etcd --nodes "$1" 2>/dev/null | grep -q "Running pre state"; do sleep 5; done' \
        _ "$SERVER_IP"
    then
        echo "Timed out waiting for etcd bootstrap readiness" >&2
        exit 1
    fi
else
    echo "Unable to access $SERVER_IP in maintenance mode" >&2
    exit 1
fi

echo "> talosctl bootstrap"
talosctl bootstrap --nodes "$SERVER_IP"

exec bash "$ROOT_DIR/scripts/conf-server.sh" "$SERVER_NAME" "$CLUSTER_NAME"
