#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <server-name>" >&2
    exit 1
fi

SERVER_NAME=$1
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

GEN_DIR=gen
SECRETS_FILE="$GEN_DIR/secrets.yaml"
TALOSCONFIG_FILE="$GEN_DIR/talosconfig"

if [ ! -f "$SECRETS_FILE" ] || [ ! -f "$TALOSCONFIG_FILE" ]; then
    echo "Talos credentials are missing; run 'mise run setup-talos $SERVER_NAME <server-ip>' first" >&2
    exit 1
fi

export TALOSCONFIG="$TALOSCONFIG_FILE"
SERVER_NODE=$(talosctl config info --output json | jq -er '.nodes[0] // .endpoints[0]')
SERVER_HOST=${SERVER_NODE#https://}
SERVER_HOST=${SERVER_HOST#http://}
SERVER_HOST=${SERVER_HOST%/}

echo "> talosctl gen config"
talosctl gen config "$SERVER_NAME" "https://$SERVER_HOST:6443" \
    --with-secrets "$SECRETS_FILE" \
    --config-patch "@config.yaml" \
    --output-types controlplane \
    --output "$GEN_DIR/controlplane.yaml" \
    --force

chmod 600 "$SECRETS_FILE" "$GEN_DIR/controlplane.yaml" "$TALOSCONFIG_FILE"

echo "> applying machine config"
talosctl apply-config \
    --nodes "$SERVER_NODE" \
    --file "$GEN_DIR/controlplane.yaml"

echo "> talosctl health"
talosctl health --nodes "$SERVER_NODE" --wait-timeout 20m
