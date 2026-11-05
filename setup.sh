#!/usr/bin/env bash
# One-click setup (Linux/macOS): k3d cluster + Linkerd + Online Boutique. Only Docker is required.
set -euo pipefail
cd "$(dirname "$0")"

K3D_VERSION=v5.9.0
KUBECTL_VERSION=v1.37.2
LINKERD_VERSION=edge-26.11.1
GATEWAY_API_VERSION=v1.2.1
APP_VERSION=v0.10.7
TOOLS="$PWD/.tools"; mkdir -p "$TOOLS"; export PATH="$TOOLS:$PATH"

command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "Docker is not installed or not running."; exit 1; }

os=$(uname -s | tr A-Z a-z)
case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) echo "Unsupported CPU"; exit 1;; esac

if ! command -v k3d >/dev/null; then
  echo ">> Downloading k3d $K3D_VERSION"
  curl -fsSL -o "$TOOLS/k3d" "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-$os-$arch"
  chmod +x "$TOOLS/k3d"
fi
if ! command -v kubectl >/dev/null; then
  echo ">> Downloading kubectl $KUBECTL_VERSION"
  curl -fsSL -o "$TOOLS/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$os/$arch/kubectl"
  chmod +x "$TOOLS/kubectl"
fi
if ! command -v linkerd >/dev/null; then
  echo ">> Downloading linkerd $LINKERD_VERSION"
  # The macOS Intel build has no architecture in its name
  case "$os-$arch" in darwin-amd64) suffix=darwin;; *) suffix="$os-$arch";; esac
  curl -fsSL -o "$TOOLS/linkerd" "https://github.com/linkerd/linkerd2/releases/download/$LINKERD_VERSION/linkerd2-cli-$LINKERD_VERSION-$suffix"
  chmod +x "$TOOLS/linkerd"
fi

if k3d cluster list sina >/dev/null 2>&1; then
  echo ">> Cluster 'sina' already exists, reusing it"
else
  k3d cluster create --config cluster/k3d-config.yaml
fi

# Linkerd generates new certificates on every install, so it must only ever run once per cluster
if kubectl get deployment linkerd-destination -n linkerd >/dev/null 2>&1; then
  echo ">> Linkerd already installed, reusing it"
else
  echo ">> Installing Linkerd"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
  linkerd install --crds | kubectl apply -f -
  linkerd install | kubectl apply -f -
  linkerd check
fi

# --native-sidecar: the proxy must be up before loadgenerator's init container calls the frontend
echo ">> Deploying Online Boutique with Linkerd proxies"
linkerd inject --native-sidecar app/kubernetes-manifests.yaml | kubectl apply -f -
echo ">> Waiting for pods (can take a few minutes)"
kubectl wait --for=condition=available deployment --all --timeout=600s
kubectl get pods

echo ">> Done. Shop at http://localhost:8080"
