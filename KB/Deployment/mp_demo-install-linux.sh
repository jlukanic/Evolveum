#!/bin/bash

set -e

# === VARIABLES ===
MP_NAMESPACE="mp-demo"
ARGO_NAMESPACE="argocd"
INGRESS_HOST="demo.example.com"
GIT_REPO="https://github.com/<git_username>/midpoint-kubernetes.git"   #Replace the <git_username> with the one of the forked repository
REPO_DIR="/opt/midpoint-kubernetes/"
GIT_BRANCH="devel" #change to other branch if needed

# === DETECT OS & SET PACKAGE MANAGER ===
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS. Exiting."
    exit 1
fi

case "$OS" in
    ubuntu|debian)
        PM_UPDATE="sudo apt-get update"
        PM_INSTALL="sudo apt-get install -y"
        SSH_SERVER="openssh-server"
        ;;
    fedora)
        PM_UPDATE="sudo dnf update -y"
        PM_INSTALL="sudo dnf install -y"
        SSH_SERVER="openssh-server"
        ;;
    centos|rhel)
        PM_UPDATE="sudo yum update -y"
        PM_INSTALL="sudo yum install -y"
        SSH_SERVER="openssh-server"
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 2
        ;;
esac

# === INSTALL DEPENDENCIES ===
echo "[+] Updating package index and installing dependencies..."
$PM_UPDATE
$PM_INSTALL curl git

# === INSTALL DEPENDENCIES + SSH ===
echo "[+] Updating package index and installing dependencies..."
$PM_UPDATE

# === INSTALL K3S ===
echo "[+] Installing K3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -

# === SETUP KUBECONFIG ===
echo "[+] Setting up kubeconfig..."
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# === INSTALL ARGO CD ===
echo "[+] Installing Argo CD..."
kubectl create namespace "$ARGO_NAMESPACE" || true
kubectl apply -n "$ARGO_NAMESPACE" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n "$ARGO_NAMESPACE" --timeout=300s

# === CLONE & PATCH MIDPOINT REPO ===
echo "[+] Cloning midpoint-kubernetes and pushing to your repo..."
git clone --branch $GIT_BRANCH "$GIT_REPO" "$REPO_DIR" || true
cd "$REPO_DIR"

# Patch options-map.yaml with intended values
echo "[+] Adjusting options-map.yaml with dynamic values..."
env_config="$REPO_DIR/midpoint-live-demo/kustomize-base/kustomize-env-config/options-map.yaml"
sed -i "s|ingress_host: .*|ingress_host: $INGRESS_HOST|g" "$env_config"
sed -i "s|cluster_domain: .*|cluster_domain: cluster.local|g" "$env_config"
sed -i "s|ingress_class_name: .*|ingress_class_name: traefik|g" "$env_config"

# Push to your GitHub repo
if [ ! -d ".git" ]; then
  git init
fi

git config user.email "autobot@midpoint.local"
git config user.name "MidPoint Argo Installer"

if ! git remote | grep origin > /dev/null; then
  git remote add origin "$GIT_REPO"
else
  git remote set-url origin "$GIT_REPO"
fi

git add $REPO_DIR/midpoint-live-demo/kustomize-base/kustomize-env-config/options-map.yaml
git commit -m "Initialize midPoint deployment with updated options-map.yaml" || echo "Nothing to commit"
git branch -M "$GIT_BRANCH"
git push -f origin "$GIT_BRANCH"

cd ~

# === DEPLOY ARGO CD APP ===
echo "[+] Creating Argo CD application for midPoint..."
kubectl apply -n "$ARGO_NAMESPACE" -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: midpoint
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: "$GIT_REPO"
    targetRevision: "$GIT_BRANCH"
    path: midpoint-live-demo/kustomize-base
  destination:
    server: https://kubernetes.default.svc
    namespace: $MP_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

# === OUTPUT INFO ===
echo
echo "✅ DONE!"
echo "➡️  Argo CD UI: http://localhost:8080"
echo "   (Run: kubectl port-forward svc/argocd-server -n argocd 8080:443)"
echo "🔑 Argo CD login: admin"
echo -n "🔑 Initial password: "; kubectl -n "$ARGO_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
echo "$ARGO_PWD" > /tmp/argopwd.txt
echo "  (also stored in /tmp/argopwd.txt)"
echo
echo "🌍 midPoint URL: https://$INGRESS_HOST"
echo "🔒 midPoint login: administrator / IGA4ever"
echo "📄 Add to /etc/hosts if needed:"
echo "127.0.0.1 $INGRESS_HOST"
