# One-click setup (Windows PowerShell 5.1+ / pwsh): k3d cluster + Online Boutique. Only Docker is required.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot

$K3dVersion = 'v5.9.0'; $KubectlVersion = 'v1.37.2'; $AppVersion = 'v0.10.7'
$Tools = Join-Path $PSScriptRoot '.tools'
New-Item -ItemType Directory -Force $Tools | Out-Null
$env:PATH = "$Tools;$env:PATH"

docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker is not installed or not running (start Docker Desktop).' }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

if (-not (Get-Command k3d -ErrorAction SilentlyContinue)) {
  Write-Host ">> Downloading k3d $K3dVersion"
  Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$K3dVersion/k3d-windows-$arch.exe" -OutFile "$Tools\k3d.exe"
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Host ">> Downloading kubectl $KubectlVersion"
  Invoke-WebRequest "https://dl.k8s.io/release/$KubectlVersion/bin/windows/$arch/kubectl.exe" -OutFile "$Tools\kubectl.exe"
}

k3d cluster list sina *> $null
if ($LASTEXITCODE -eq 0) {
  Write-Host ">> Cluster 'sina' already exists, reusing it"
} else {
  k3d cluster create --config cluster/k3d-config.yaml
  if ($LASTEXITCODE -ne 0) { throw 'Cluster creation failed' }
}

kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$AppVersion/release/kubernetes-manifests.yaml"
Write-Host '>> Waiting for pods (can take a few minutes)'
kubectl wait --for=condition=available deployment --all --timeout=600s
kubectl get pods

Write-Host '>> Done. Shop at http://localhost:8081 (Ctrl+C to stop port-forward)'
kubectl port-forward svc/frontend 8081:80
