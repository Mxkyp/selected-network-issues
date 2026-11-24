# Turns the Zero-Trust authorization policies on and off (Windows PowerShell 5.1+ / pwsh; Linux/macOS: zero-trust.sh).
#
#   .\zero-trust.ps1 status     what is enabled right now
#   .\zero-trust.ps1 on         phase 1: per-service policies from policies\ + attacker test pods
#   .\zero-trust.ps1 off        back to the unprotected cluster (turns phase 2 off first if needed)
#   .\zero-trust.ps1 deny on    phase 2: namespace default-deny (restarts every pod, one at a time)
#   .\zero-trust.ps1 deny off   phase 2 off again (restarts every pod, one at a time)
#
# Details: policies\README.md and policies\namespace-default-deny\README.md.
param(
  [Parameter(Position = 0)][string]$Command = 'status',
  [Parameter(Position = 1)][string]$Option = ''
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$Tools = Join-Path $PSScriptRoot '.tools'
if (Test-Path $Tools) { $env:PATH = "$Tools$([IO.Path]::PathSeparator)$env:PATH" }

$Ns = 'default'
$Phase1 = 'app.kubernetes.io/part-of=zero-trust-policies'
$Phase2 = 'app.kubernetes.io/part-of=zero-trust-default-deny'
$Attackers = 'app.kubernetes.io/part-of=attack-simulation'
$DenyKey = 'config.linkerd.io/default-inbound-policy'

# kubectl that stops the script on a non-zero exit code (native commands do not throw by themselves)
function kc {
  $out = & kubectl @args
  if ($LASTEXITCODE -ne 0) { throw "kubectl $($args -join ' ') failed" }
  $out
}
# JSON output parsed into objects; avoids jsonpath, whose quotes Windows PowerShell 5.1 mangles
function Get-KubeJson { kc @args -o json | Out-String | ConvertFrom-Json }

function Show-Usage { Get-Content $PSCommandPath -TotalCount 9 | Select-Object -Skip 1 | ForEach-Object { $_ -replace '^# ?', '' } }

function Get-Phase1Count { @((Get-KubeJson get servers.policy.linkerd.io -n $Ns -l $Phase1).items).Count }
function Get-Phase1Total { @(Get-ChildItem policies -Filter *.yaml | Where-Object { Select-String -Path $_.FullName -Pattern '^kind: Server' -Quiet }).Count }
function Get-DenyValue { (Get-KubeJson get namespace $Ns).metadata.annotations.$DenyKey }

# Restart every deployment one at a time: restarting them all at once overloads a laptop.
function Restart-All {
  foreach ($d in (kc get deploy -n $Ns -o name)) {
    Write-Host ">> Restarting $d"
    kc rollout restart -n $Ns $d | Out-Null
    kc rollout status -n $Ns $d --timeout=300s | Out-Null
  }
}

function Add-Attackers {
  Write-Host '>> Attacker test pods'
  kc apply -f attack/attackers.yaml | Out-Null
  kc wait --for=condition=Ready pod -n $Ns -l $Attackers --timeout=180s | Out-Null
}

# The attacker pods are plain pods: they must be recreated to pick up a new default policy.
function Reset-Attackers {
  kc delete pod -n $Ns -l $Attackers --ignore-not-found | Out-Null
  Add-Attackers
}

function Show-Status {
  $n = Get-Phase1Count; $total = Get-Phase1Total
  if ($n -eq 0) { Write-Host 'Phase 1 (per-service policies): OFF - the cluster is unprotected' }
  elseif ($n -eq $total) { Write-Host "Phase 1 (per-service policies): ON ($n/$total Servers)" }
  else { Write-Host "Phase 1 (per-service policies): PARTIAL ($n/$total Servers) - run: .\zero-trust.ps1 on" }
  if ((Get-DenyValue) -eq 'deny') { Write-Host 'Phase 2 (namespace default-deny): ON' }
  else { Write-Host 'Phase 2 (namespace default-deny): OFF' }
  $att = @((Get-KubeJson get pods -n $Ns -l $Attackers).items | ForEach-Object {
    $ready = @($_.status.containerStatuses | Where-Object { $_.ready }).Count
    "$($_.metadata.name)($ready/$(@($_.spec.containers).Count))"
  })
  if ($att.Count -gt 0) { Write-Host "Attacker test pods: $($att -join ' ')" }
  else { Write-Host 'Attacker test pods: none (kubectl apply -f attack/attackers.yaml, or re-run .\setup.ps1)' }
  $unmeshed = @((Get-KubeJson get pods -A).items | Where-Object {
    $names = @($_.spec.containers.name) + @($_.spec.initContainers.name)
    $_.metadata.annotations.'linkerd.io/inject' -eq 'enabled' -and $names -notcontains 'linkerd-proxy'
  } | ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" })
  if ($unmeshed.Count -gt 0) { Write-Host "WARNING: pods without the Linkerd proxy (re-run .\setup.ps1 to fix): $($unmeshed -join ' ')" }
}

function Enable-Policies {
  Write-Host '>> Applying the per-service policies (policies\)'
  kc apply -f policies/ | Out-Null
  Add-Attackers
  Write-Host '>> Done. Give the proxies a few seconds before testing: attack/verify.sh (from Git Bash)'
}

function Disable-Policies {
  if ((Get-DenyValue) -eq 'deny') { Disable-Deny }
  Write-Host '>> Removing the per-service policies'
  # By label with Servers first: a Server whose authorizations are already gone denies everything.
  kc delete -n $Ns 'server,grpcroute,authorizationpolicy,meshtlsauthentication,networkauthentication' -l $Phase1 | Out-Null
  Add-Attackers
  Write-Host '>> Done. The cluster is unprotected: attack/verify.sh --expect-open'
}

function Enable-Deny {
  if ((Get-Phase1Count) -ne (Get-Phase1Total)) {
    Write-Host 'Phase 1 is not fully on; default-deny without it blocks the whole shop. Run .\zero-trust.ps1 on first.'
    exit 1
  }
  if (-not (kc get deploy -n linkerd-viz prometheus --ignore-not-found -o name)) {
    Write-Host 'NOTE: linkerd-viz is not installed, so after this nothing may scrape the proxy metrics. See policies\namespace-default-deny\README.md.'
  }
  Write-Host '>> Applying the proxy admin port policy'
  kc apply -f policies/namespace-default-deny/admin-port.yaml | Out-Null
  kc annotate namespace $Ns "$DenyKey=deny" --overwrite | Out-Null
  Restart-All
  Reset-Attackers
  Write-Host '>> Done. Phase 2 is on.'
}

function Disable-Deny {
  Write-Host '>> Turning namespace default-deny off'
  if (Get-DenyValue) { kc annotate namespace $Ns "$DenyKey-" | Out-Null }
  Restart-All
  kc delete -n $Ns 'server,httproutes.policy.linkerd.io,authorizationpolicy,meshtlsauthentication' -l $Phase2 | Out-Null
  Reset-Attackers
  Write-Host '>> Done. Phase 2 is off.'
}

switch ("$Command $Option".Trim()) {
  'status'   { Show-Status }
  'on'       { Enable-Policies; Show-Status }
  'off'      { Disable-Policies; Show-Status }
  'deny on'  { Enable-Deny; Show-Status }
  'deny off' { Disable-Deny; Show-Status }
  { $_ -in 'help', '-h', '--help' } { Show-Usage }
  default    { Show-Usage; exit 2 }
}
