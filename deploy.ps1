# One command on the Windows host: create the VMs, then configure everything
# from the WSL control node.
#
#   .\deploy.ps1 -Environment staging
#   .\deploy.ps1 -Environment production -AnsibleArgs '--tags','haproxy'
#   $env:VM_MEMORY_SCALE = "1.5"; .\deploy.ps1   # bigger VMs on a bigger host
param(
    [ValidateSet('production', 'staging')]
    [string]$Environment = 'production',
    [string[]]$AnsibleArgs = @()
)
# Not 'Stop': Windows PowerShell 5.1 turns any stderr line of a native program
# (e.g. an Ansible warning) into a terminating error when output is redirected,
# which killed healthy runs. Failures are detected through exit codes instead.
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

$env:ENV = $Environment
vagrant up
if ($LASTEXITCODE -ne 0) { throw "vagrant up failed" }

$wslPath = (wsl wslpath -a ($PSScriptRoot -replace '\\', '/')).Trim()
wsl --cd $wslPath bash ./deploy.sh $Environment @AnsibleArgs
if ($LASTEXITCODE -ne 0) { Write-Host "deploy.sh failed (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
Write-Host "Done: $Environment is deployed and verified."
