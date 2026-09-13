#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <server-name> <server-ip>" >&2
    exit 1
fi

SERVER_NAME=$1
SERVER_IP=$2
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SERVER_DIR="$ROOT_DIR/vps/$SERVER_NAME"

if [[ "$SERVER_NAME" == */* ]] || [ "$SERVER_NAME" = "." ] || [ "$SERVER_NAME" = ".." ]; then
    echo "Invalid server name: $SERVER_NAME" >&2
    exit 1
fi

if [ ! -f "$SERVER_DIR/config.yaml" ]; then
    echo "Server configuration not found: $SERVER_DIR/config.yaml" >&2
    exit 1
fi

cd "$SERVER_DIR"
umask 077

TALOS_DIR=.talos
SECRETS_FILE="$TALOS_DIR/secrets.yaml"
TALOSCONFIG_FILE="$TALOS_DIR/talosconfig"

mkdir -p "$TALOS_DIR"

if [ -f "$SECRETS_FILE" ]; then
    echo "> reusing $SECRETS_FILE"
elif [ -e "$TALOS_DIR/controlplane.yaml" ] || [ -e "$TALOSCONFIG_FILE" ]; then
    echo "Refusing to generate new secrets while existing cluster files are present" >&2
    echo "Restore $SECRETS_FILE or remove the entire $TALOS_DIR directory" >&2
    exit 1
else
    echo "> talosctl gen secrets"
    talosctl gen secrets --output-file "$SECRETS_FILE"
fi

echo "> talosctl gen config"
talosctl gen config "$SERVER_NAME" "https://$SERVER_IP:6443" \
    --with-secrets "$SECRETS_FILE" \
    --config-patch "@config.yaml" \
    --output-types controlplane,talosconfig \
    --output "$TALOS_DIR" \
    --force

chmod 600 "$SECRETS_FILE" "$TALOS_DIR/controlplane.yaml" "$TALOSCONFIG_FILE"

export TALOSCONFIG="$TALOSCONFIG_FILE"
talosctl config endpoints "$SERVER_IP"
talosctl config node "$SERVER_IP"

if timeout 10s talosctl get machineconfig \
    --nodes "$SERVER_IP" \
    --endpoints "$SERVER_IP" >/dev/null 2>&1
then
    if ! talosctl service etcd --nodes "$SERVER_IP" 2>/dev/null | grep -q "Running pre state"; then
        echo "Talos is already configured; use 'mise run conf-server $SERVER_NAME'" >&2
        exit 1
    fi
    echo "> resuming setup before etcd bootstrap"
elif timeout 10s talosctl version \
    --nodes "$SERVER_IP" \
    --endpoints "$SERVER_IP" \
    --insecure >/dev/null 2>&1
then
    echo "> applying initial machine config"
    talosctl apply-config \
        --insecure \
        --nodes "$SERVER_IP" \
        --file "$TALOS_DIR/controlplane.yaml"

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

echo "> talosctl health"
talosctl health --nodes "$SERVER_IP" --wait-timeout 20m
