function Invoke-AapDemoCreate {
  [CmdletBinding()]
  param(
    [switch]$Embedded
  )

  if (-not $Embedded) {
    Write-AapHeader 'aap-demo create'
  }

  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'

  $status = Get-AapCrcStatus
  $crcState = [string]$status.crcStatus
  if ($crcState -eq 'Running') {
    throw 'CRC already running. Run aap-demo deploy or destroy the cluster first.'
  }

  $preset = Get-AapConfigValue 'CRC_PRESET'
  if (-not $preset) {
    Write-Host 'Select CRC preset:'
    Write-Host '  1) microshift (recommended)'
    Write-Host '  2) openshift'
    $choice = Read-Host 'Choice [1]'
    $preset = switch ($choice) {
      '2' { 'openshift' }
      'openshift' { 'openshift' }
      default { 'microshift' }
    }
    Set-AapConfigValue 'CRC_PRESET' $preset
  }

  $cpus = if ($env:CRC_CPUS) { $env:CRC_CPUS } elseif (Get-AapConfigValue 'CRC_CPUS') { Get-AapConfigValue 'CRC_CPUS' } else { '8' }
  $memory = if ($env:CRC_MEMORY) { $env:CRC_MEMORY } elseif (Get-AapConfigValue 'CRC_MEMORY') { Get-AapConfigValue 'CRC_MEMORY' } else { '16384' }
  $configuredDisk = Get-AapConfigValue 'CRC_DISK'
  if ($env:CRC_DISK) {
    $disk = $env:CRC_DISK
  } elseif ($configuredDisk) {
    $disk = $configuredDisk
  } elseif ($crcState -eq 'Unknown') {
    Write-Host 'Select CRC disk size:'
    Write-Host '  1) 180 GB (minimum; 100 GB for root/container images)'
    Write-Host '  2) 220 GB'
    Write-Host '  3) 270 GB'
    Write-Host '  4) 320 GB'
    $diskChoice = Read-Host 'Choice [1]'
    $disk = switch ($diskChoice) {
      { $_ -in @('', '1', '180') } { '180'; break }
      { $_ -in @('2', '220') } { '220'; break }
      { $_ -in @('3', '270') } { '270'; break }
      { $_ -in @('4', '320') } { '320'; break }
      default { throw "Invalid disk choice '$diskChoice'. Choose 1, 2, 3, or 4." }
    }
  } else {
    $disk = '180'
  }

  $configuredPvSize = Get-AapConfigValue 'CRC_PV_SIZE'
  if ($env:CRC_PV_SIZE) {
    $pvSize = $env:CRC_PV_SIZE
  } elseif ($configuredPvSize) {
    $pvSize = $configuredPvSize
  } elseif ([int]$disk -gt 70) {
    $pvSize = '70'
  } elseif ([int]$disk -gt 30) {
    $pvSize = "$([int]$disk - 30)"
  } else {
    $pvSize = [string][Math]::Max(1, ([int]$disk - 1))
  }

  $minimumImageSize = if ($env:AAP_DEMO_MIN_IMAGE_STORAGE_GIB) {
    [int]$env:AAP_DEMO_MIN_IMAGE_STORAGE_GIB
  } else {
    100
  }
  if ($minimumImageSize -le 0) {
    throw 'AAP_DEMO_MIN_IMAGE_STORAGE_GIB must be a positive integer'
  }
  $minimumDisk = [int]([Math]::Ceiling(([int]$pvSize + $minimumImageSize + 1) / 10.0) * 10)
  if ([int]$disk -lt $minimumDisk) {
    Write-AapWarn "CRC_DISK=${disk}GB leaves less than ${minimumImageSize}GB for root/container images; increasing to ${minimumDisk}GB."
    $disk = [string]$minimumDisk
  }

  Set-AapConfigValue 'CRC_DISK' $disk
  Set-AapConfigValue 'CRC_PV_SIZE' $pvSize

  if ($env:QUIET -ne 'true') {
    $cpuChoice = Read-Host "CPUs [$cpus]"
    if (-not [string]::IsNullOrWhiteSpace($cpuChoice)) { $cpus = $cpuChoice.Trim() }

    $memoryGbDefault = [int][Math]::Ceiling(([int]$memory) / 1024)
    $memoryChoice = Read-Host "Memory in GB [$memoryGbDefault]"
    if (-not [string]::IsNullOrWhiteSpace($memoryChoice)) {
      $memory = ([int]$memoryChoice.Trim()) * 1024
    }

    Set-AapConfigValue 'CRC_CPUS' $cpus
    Set-AapConfigValue 'CRC_MEMORY' $memory
  }

  & crc config set preset $preset 2>$null | Out-Null
  & crc config set cpus $cpus 2>$null | Out-Null
  & crc config set memory $memory 2>$null | Out-Null
  & crc config set disk-size $disk 2>$null | Out-Null
  & crc config set persistent-volume-size $pvSize 2>$null | Out-Null
  Write-AapStep "Preset $preset | CPUs $cpus | Memory $memory MiB | Disk ${disk}GB"

  if ($crcState -eq 'Unknown') {
    Write-AapStep 'Running crc setup...'
    & crc setup --show-progressbars
    if ($LASTEXITCODE -ne 0) { throw 'crc setup failed' }
  }

  $pullSecret = Get-AapPullSecretPath
  if (-not $pullSecret) {
    throw "Pull secret not found. Save to $Script:AapDemoConfigDir\pull-secret.txt"
  }
  Write-AapStep "Pull secret: $pullSecret"

  Write-AapStep 'Starting CRC (this may take several minutes)...'
  Invoke-AapCrcStart -PullSecretPath $pullSecret

  Initialize-AapKubeEnvironment

  if ($preset -eq 'microshift') {
    Write-AapStep 'Configuring nip.io baseDomain...'
    Invoke-AapCrcSsh 'sudo mkdir -p /etc/microshift/config.d && printf ''%s\n'' ''dns:'' ''  baseDomain: 127.0.0.1.nip.io'' | sudo tee /etc/microshift/config.d/99-aap-demo-dns.yaml > /dev/null' | Out-Null
    $dnsConfig = Invoke-AapCrcSsh 'sudo cat /etc/microshift/config.d/99-aap-demo-dns.yaml'
    if ($dnsConfig -notmatch 'baseDomain:\s+127\.0\.0\.1\.nip\.io') {
      throw "MicroShift DNS config invalid:`n$dnsConfig"
    }

    Write-AapStep 'Restarting MicroShift with nip.io domain...'
    Invoke-AapCrcSsh 'sudo systemctl stop microshift 2>/dev/null; sudo rm -rf /var/lib/microshift; sudo systemctl reset-failed microshift 2>/dev/null; sudo systemctl start microshift 2>/dev/null || true' -AllowFailure | Out-Null

    Write-AapStep 'Waiting for MicroShift API...'
    for ($i = 1; $i -le 60; $i++) {
      if (Test-AapCrcSsh 'sudo kubectl --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig cluster-info') {
        break
      }
      if ($i -eq 60) { throw 'MicroShift API did not become ready' }
      Start-Sleep -Seconds 5
    }

    $aapKube = Join-Path $Script:AapDemoConfigDir 'kubeconfig.microshift'
    New-Item -ItemType Directory -Force -Path $Script:AapDemoConfigDir | Out-Null
    Invoke-AapCrcSsh 'sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig' |
      Set-Content -LiteralPath $aapKube -Encoding ascii
    $env:KUBECONFIG = $aapKube

    Write-AapStep 'Installing metrics-server...'
    if ((Invoke-AapOcQuiet @('get', 'deployment', 'metrics-server', '-n', 'kube-system')) -ne 0) {
      Invoke-AapOc @('apply', '-f', 'https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml') | Out-Null
    }
    $metricsPatch = '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    $metricsArgs = Invoke-AapOcCapture @(
      'get', 'deployment', 'metrics-server', '-n', 'kube-system',
      '-o', 'jsonpath={.spec.template.spec.containers[0].args}'
    )
    if ($metricsArgs.ExitCode -eq 0 -and $metricsArgs.Output -notmatch 'kubelet-insecure-tls') {
      if ((Invoke-AapOcPatchQuiet @('patch', 'deployment', 'metrics-server', '-n', 'kube-system') -Patch $metricsPatch -PatchType 'json') -ne 0) {
        Write-AapWarn 'Could not patch metrics-server for --kubelet-insecure-tls'
      }
    }

    if ((Invoke-AapOcQuiet @('get', 'sc', 'nfs-local-rwx')) -ne 0) {
      Write-AapStep 'Setting up nfs-local-rwx storage...'
      Invoke-AapOc @('adm', 'policy', 'add-scc-to-group', 'privileged', 'system:serviceaccounts:nfs-storage') | Out-Null
      $defaultSc = Get-AapDefaultStorageClass
      Apply-AapManifestTemplate 'config/manifests/nfs-server.yaml' @{ '__DEFAULT_SC__' = $defaultSc }
      Invoke-AapOc @('wait', '--for=condition=Available', 'deployment/nfs-server', '-n', 'nfs-storage', '--timeout=120s') | Out-Null
      $nfsIp = Get-AapServiceClusterIp -Name 'nfs-server' -Namespace 'nfs-storage'
      Apply-AapManifestTemplate 'config/manifests/nfs-provisioner.yaml' @{ '__NFS_SERVER_IP__' = $nfsIp }
      Invoke-AapOc @('wait', '--for=condition=Available', 'deployment/nfs-provisioner', '-n', 'nfs-storage', '--timeout=120s') | Out-Null
    }

    Write-AapStep 'Configuring CoreDNS for in-cluster routes...'
    Set-AapCoreDns -RouteDomain 'apps.127.0.0.1.nip.io'

    Write-AapStep 'Tuning inotify limits on cluster node...'
    Invoke-AapCrcSsh 'sudo sysctl -w fs.inotify.max_user_watches=2099999999 fs.inotify.max_user_instances=2099999999 fs.inotify.max_queued_events=2099999999' | Out-Null
  }

  Install-AapOlm

  try {
    Sync-AapKubeconfig -Quiet
  } catch {
    Write-AapWarn "Kubeconfig sync skipped: $($_.Exception.Message)"
  }

  $kubeConfig = Get-AapKubeconfigPath
  Write-Host ''
  Write-AapStep 'CRC cluster ready'
  Write-Host "  Kubeconfig: $kubeConfig"
  if (-not $Embedded) {
    Write-Host '  Next: aap-demo deploy'
    Write-Host ''
  }
}

function Invoke-AapEnsureCluster {
  param(
    [switch]$CreateIfMissing
  )

  $crc = Get-AapCrcStatus
  if ([string]$crc.crcStatus -eq 'Stopped') {
    Write-AapStep 'Cluster stopped - starting CRC...'
    Invoke-AapCrcStart
  } elseif ([string]$crc.crcStatus -eq 'Unknown') {
    if ($CreateIfMissing) {
      Write-AapStep 'No cluster found - creating OpenShift Local cluster...'
      Write-Host ''
      Invoke-AapDemoCreate -Embedded
    } else {
      throw 'No cluster found. Run: aap-demo create'
    }
  }

  Initialize-AapKubeEnvironment
  if ((Invoke-AapOcQuiet @('cluster-info')) -ne 0) {
    throw 'oc cannot connect to cluster'
  }
}

function Set-AapCoreDns {
  param([Parameter(Mandatory)][string]$RouteDomain)

  $escaped = [regex]::Escape($RouteDomain)
  $corefile = @"
.:5353 {
    bufsize 1232
    errors
    log . {
        class error
    }
    health {
        lameduck 20s
    }
    ready
    rewrite stop {
        name regex (.*)\.$escaped router-internal-default.openshift-ingress.svc.cluster.local
        answer auto
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    prometheus 127.0.0.1:9153
    forward . /etc/resolv.conf {
        policy sequential
    }
    cache 900 {
        denial 9984 30
    }
    reload
}
"@

  $patch = @{ data = @{ Corefile = $corefile } } | ConvertTo-Json -Compress
  Invoke-AapOcPatchQuiet @('patch', 'configmap', 'dns-default', '-n', 'openshift-dns') -Patch $patch | Out-Null
  Invoke-AapOcQuiet @('rollout', 'restart', 'daemonset/dns-default', '-n', 'openshift-dns') | Out-Null
}
