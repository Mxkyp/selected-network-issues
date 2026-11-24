# One-click setup (Windows PowerShell 5.1+ / pwsh): k3d cluster + Linkerd + Online Boutique. Only Docker is required.
#   .\setup.ps1            meshed (mTLS) but without authorization policies: the "before" state of the demo
#   .\setup.ps1 -Protect   the same, then turns the Zero-Trust policies on (.\zero-trust.ps1 on)
param([switch]$Protect)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot

$K3dVersion = 'v5.9.0'; $KubectlVersion = 'v1.37.2'; $LinkerdVersion = 'edge-26.11.1'; $GatewayApiVersion = 'v1.2.1'
$Tools = Join-Path $PSScriptRoot '.tools'
New-Item -ItemType Directory -Force $Tools | Out-Null
$env:PATH = "$Tools$([IO.Path]::PathSeparator)$env:PATH"

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
  # A stopped cluster (for example after a Docker restart) shows e.g. "0/1" running servers
  $fields = (k3d cluster list sina --no-headers | Select-Object -First 1) -split '\s+'
  $servers = $fields[1] -split '/'; $agents = $fields[2] -split '/'
  if ([int]$servers[0] -lt [int]$servers[1] -or [int]$agents[0] -lt [int]$agents[1]) {
    Write-Host '>> Cluster is stopped, starting it'
    k3d cluster start sina
    if ($LASTEXITCODE -ne 0) { throw 'Starting the cluster failed' }
  }
} else {
  k3d cluster create --config cluster/k3d-config.yaml
  if ($LASTEXITCODE -ne 0) { throw 'Cluster creation failed' }
}

Write-Host '>> Waiting for the Kubernetes API and nodes'
for ($i = 0; $i -lt 60; $i++) {
  if (Test-Command { kubectl get --raw /readyz }) { break }
  Start-Sleep -Seconds 5
}
kubectl wait --for=condition=Ready node --all --timeout=300s
if ($LASTEXITCODE -ne 0) { throw 'The cluster did not become ready' }

# Linkerd generates new certificates on every install, so it must only ever run once per cluster.
# --ignore-not-found prints nothing when Linkerd is missing but still fails if the API is unreachable,
# so an unreachable cluster stops the script instead of triggering a second install.
$linkerdFound = kubectl get deployment linkerd-destination -n linkerd --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) { throw 'Cannot reach the cluster to check for Linkerd' }
if ($linkerdFound) {
  Write-Host '>> Linkerd already installed, reusing it'
  # After a restart the control plane needs a moment; injecting before it is ready fails
  kubectl wait --for=condition=available deployment --all -n linkerd --timeout=600s
  if ($LASTEXITCODE -ne 0) { throw 'Linkerd control plane is not ready' }
  # Pods recreated while the proxy injector was still down came up without a proxy, so they have
  # no identity and the authorization policies treat them as outsiders. Recreate them.
  $pods = (kubectl get pods -A -o json | Out-String | ConvertFrom-Json).items
  foreach ($pod in $pods) {
    $names = @($pod.spec.containers.name) + @($pod.spec.initContainers.name)
    if ($pod.metadata.annotations.'linkerd.io/inject' -eq 'enabled' -and $names -notcontains 'linkerd-proxy') {
      Write-Host ">> Recreating $($pod.metadata.namespace)/$($pod.metadata.name) (started without the Linkerd proxy)"
      kubectl delete pod -n $pod.metadata.namespace $pod.metadata.name --wait=false
    }
  }
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

$zeroTrust = Join-Path $PSScriptRoot 'zero-trust.ps1'
if ($Protect) {
  & $zeroTrust on
} else {
  # Attacker test pods for the "before" demo (attack/attack.sh, attack/verify.sh --expect-open)
  kubectl apply -f attack/attackers.yaml | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Applying the attacker test pods failed' }
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/part-of=attack-simulation --timeout=180s | Out-Null
  Write-Host ''
  & $zeroTrust status
  Write-Host 'To turn the Zero-Trust policies on: .\zero-trust.ps1 on   (or run .\setup.ps1 -Protect)'
}

Write-Host '>> Done. Shop at http://localhost:8080'
