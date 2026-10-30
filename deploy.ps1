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
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$env:ENV = $Environment
vagrant up
if ($LASTEXITCODE -ne 0) { throw "vagrant up failed" }

$wslPath = (wsl wslpath -a ($PSScriptRoot -replace '\\', '/')).Trim()
wsl --cd $wslPath bash ./deploy.sh $Environment @AnsibleArgs
exit $LASTEXITCODE
