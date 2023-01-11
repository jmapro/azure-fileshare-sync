Param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $aciRG,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $aciName,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $aciSubscriptionID,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $aciContainerName
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Connect to Azure with system-assigned managed identity (automation account)
Connect-AzAccount -Identity

# SOURCE Azure Subscription
Select-AzSubscription -SubscriptionId $aciSubscriptionID

Start-AzContainerGroup -Name $aciName -ResourceGroupName $aciRG

$CG=Get-AzContainerGroup -Name $aciName -ResourceGroupName $aciRG

while ((Get-AzContainerGroup -Name $aciName -ResourceGroupName $aciRG).Container.CurrentState == "Running"){
  Write-Host("Waiting for the container to end.")
  Start-Sleep 30
}

$containerLogs=Get-AzContainerInstanceLog -ContainerGroupName $aciName -ResourceGroupName $aciRG  -ContainerName $aciContainerName
Write-Host($containerLogs)
