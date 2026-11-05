# One-click setup (Windows PowerShell 5.1+ / pwsh): k3d cluster + Linkerd + Online Boutique. Only Docker is required.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot

$K3dVersion = 'v5.9.0'; $KubectlVersion = 'v1.37.2'; $LinkerdVersion = 'edge-26.11.1'; $GatewayApiVersion = 'v1.2.1'
$Tools = Join-Path $PSScriptRoot '.tools'
New-Item -ItemType Directory -Force $Tools | Out-Null
$env:PATH = "$Tools;$env:PATH"

# Exit-code check. Stop must be off here: PS 5.1 turns redirected stderr of native commands into terminating errors
function Test-Command([scriptblock]$Command) {
  $ErrorActionPreference = 'Continue'
  & $Command *> $null
  $LASTEXITCODE -eq 0
}

# A native pipeline only reports the last command's exit code, so generate and apply in two steps
function Install-Manifests([scriptblock]$Generate, [string]$Name) {
  $manifests = & $Generate
  if ($LASTEXITCODE -ne 0) { throw "Generating $Name failed" }
  $manifests | kubectl apply -f -
  if ($LASTEXITCODE -ne 0) { throw "Applying $Name failed" }
}

if (-not (Test-Command { docker info })) { throw 'Docker is not installed or not running (start Docker Desktop).' }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

if (-not (Get-Command k3d -ErrorAction SilentlyContinue)) {
  Write-Host ">> Downloading k3d $K3dVersion"
  Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$K3dVersion/k3d-windows-$arch.exe" -OutFile "$Tools\k3d.exe"
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Host ">> Downloading kubectl $KubectlVersion"
  Invoke-WebRequest "https://dl.k8s.io/release/$KubectlVersion/bin/windows/$arch/kubectl.exe" -OutFile "$Tools\kubectl.exe"
}
if (-not (Get-Command linkerd -ErrorAction SilentlyContinue)) {
  Write-Host ">> Downloading linkerd $LinkerdVersion"
  Invoke-WebRequest "https://github.com/linkerd/linkerd2/releases/download/$LinkerdVersion/linkerd2-cli-$LinkerdVersion-windows.exe" -OutFile "$Tools\linkerd.exe"
}

if (Test-Command { k3d cluster list sina }) {
  Write-Host ">> Cluster 'sina' already exists, reusing it"
} else {
  k3d cluster create --config cluster/k3d-config.yaml
  if ($LASTEXITCODE -ne 0) { throw 'Cluster creation failed' }
}

# Linkerd generates new certificates on every install, so it must only ever run once per cluster
if (Test-Command { kubectl get deployment linkerd-destination -n linkerd }) {
  Write-Host '>> Linkerd already installed, reusing it'
} else {
  Write-Host '>> Installing Linkerd'
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GatewayApiVersion/standard-install.yaml"
  if ($LASTEXITCODE -ne 0) { throw 'Applying Gateway API CRDs failed' }
  Install-Manifests { linkerd install --crds } 'Linkerd CRDs'
  Install-Manifests { linkerd install } 'Linkerd control plane'
  linkerd check
  if ($LASTEXITCODE -ne 0) { throw 'Linkerd is not healthy' }
}

# --native-sidecar: the proxy must be up before loadgenerator's init container calls the frontend
Write-Host '>> Deploying Online Boutique with Linkerd proxies'
Install-Manifests { linkerd inject --native-sidecar app/kubernetes-manifests.yaml } 'Online Boutique'
Write-Host '>> Waiting for pods (can take a few minutes)'
kubectl wait --for=condition=available deployment --all --timeout=600s
if ($LASTEXITCODE -ne 0) { throw 'Some deployments did not become available' }
kubectl get pods

Write-Host '>> Done. Shop at http://localhost:8080'
