#requires -Version 7.0
<# Azure for Students / FCM-RG. Por defecto valida sin modificar Azure.
   -Deploy despliega computo. Reutiliza las redes existentes sin redesplegarlas. #>
[CmdletBinding()]
param(
 [string]$SubscriptionId = '888b40f9-4bb8-49c3-8a68-377ce6a21fd2',
 [string]$ResourceGroupName = 'FCM-RG',
 [string]$VmDeploymentName = 'Deploy-Compute-Foundation',
 [string]$NetworkTemplateFile = "$PSScriptRoot/lab-network-template.json",
 [string]$NetworkParameterFile = "$PSScriptRoot/lab-network-parameters.json",
 [string]$VmTemplateFile = "$PSScriptRoot/lab-vm-template.json",
 [string]$VmParameterFile = "$PSScriptRoot/lab-vm-parameters.json",
 [string]$RdpAllowedSourceAddressPrefix,
 [securestring]$AdminPassword,
 [switch]$Deploy
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Write-Step([string]$Message) { Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Assert-ArmValidation([hashtable]$Arguments) {
 # El cmdlet puede devolver objetos de error: no descartar con Out-Null.
 $validationErrors = @(Test-AzResourceGroupDeployment @Arguments -ErrorAction Stop)
 if ($validationErrors.Count -gt 0) { throw ($validationErrors | ConvertTo-Json -Depth 30) }
}
Write-Step 'Comprobando archivos y contratos locales'
foreach ($file in @($NetworkTemplateFile,$NetworkParameterFile,$VmTemplateFile,$VmParameterFile)) {
 if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Falta archivo: $file" }
}
$networkTemplate = Get-Content -LiteralPath $NetworkTemplateFile -Raw | ConvertFrom-Json -AsHashtable
$networkParams = (Get-Content -LiteralPath $NetworkParameterFile -Raw | ConvertFrom-Json -AsHashtable).parameters
$vmTemplate = Get-Content -LiteralPath $VmTemplateFile -Raw | ConvertFrom-Json -AsHashtable
$vmParams = (Get-Content -LiteralPath $VmParameterFile -Raw | ConvertFrom-Json -AsHashtable).parameters
foreach ($pair in @(@($networkTemplate,$networkParams),@($vmTemplate,$vmParams))) {
 foreach ($key in $pair[1].Keys) {
  if (-not $pair[0].parameters.ContainsKey($key)) { throw "Parametro no declarado: $key" }
  $definition = $pair[0].parameters[$key]
  if ($definition.ContainsKey('allowedValues') -and $pair[1][$key].value -notin $definition.allowedValues) { throw "Valor no admitido: $key" }
 }
 foreach ($key in $pair[0].parameters.Keys) {
  if ($key -ne 'adminPassword' -and -not $pair[1].ContainsKey($key) -and -not $pair[0].parameters[$key].ContainsKey('defaultValue')) { throw "Falta parametro: $key" }
 }
}
$allowedLocations = @('chilecentral','mexicocentral','francecentral','northcentralus','spaincentral')
foreach ($key in @('coreLocation','manufacturingLocation','researchLocation')) {
 if ($networkParams[$key].value -notin $allowedLocations) { throw "Region fuera de politica diagnosticada: $key" }
}
if ($vmParams.location.value -ne $networkParams.coreLocation.value -or
 $vmParams.existingVirtualNetworkName.value -ne $networkParams.coreVnetName.value -or
 $vmParams.existingSubnetName.value -ne $networkParams.coreDatabaseSubnetName.value) { throw 'Red y computo deben coincidir en region, VNet y subnet.' }
if ($vmParams.vmName1.value -eq $vmParams.vmName2.value) { throw 'Los nombres de VM deben ser distintos.' }
# RDP privado por defecto; para acceso desde Internet especificar una unica IPv4 /32.
if ($RdpAllowedSourceAddressPrefix) { $vmParams.rdpAllowedSourceAddressPrefix.value = $RdpAllowedSourceAddressPrefix }
$rdpSource = $vmParams.rdpAllowedSourceAddressPrefix.value
if ($rdpSource -ne 'VirtualNetwork') {
 $ip = $null
 if ($rdpSource -notmatch '^\d{1,3}(\.\d{1,3}){3}/32$' -or -not [Net.IPAddress]::TryParse(($rdpSource -split '/')[0],[ref]$ip)) { throw 'Use VirtualNetwork o la IPv4 publica del administrador con /32 para RDP.' }
}
Write-Step 'Verificando suscripcion y redes existentes'
$context = Get-AzContext
if ($null -eq $context -or $context.Subscription.Id -ne $SubscriptionId) { throw "Seleccione la suscripcion: Set-AzContext -SubscriptionId $SubscriptionId" }
$null = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
# La ubicacion eastus del grupo no determina la ubicacion de sus recursos.
foreach ($role in @('core','manufacturing','research')) {
 $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $networkParams["${role}VnetName"].value -ErrorAction Stop
 if ($vnet.Location -ne $networkParams["${role}Location"].value) { throw "Region real distinta: $($vnet.Name)" }
 if ($networkParams["${role}AddressSpace"].value -notin $vnet.AddressSpace.AddressPrefixes) { throw "Direccionamiento distinto: $($vnet.Name)" }
 foreach ($key in @($networkParams.Keys | Where-Object { $_ -like "${role}*SubnetName" })) {
  $subnet = @($vnet.Subnets | Where-Object Name -EQ $networkParams[$key].value)
  $prefixKey = $key -replace 'Name$','Prefix'
  if ($subnet.Count -ne 1 -or $subnet[0].AddressPrefix -ne $networkParams[$prefixKey].value) { throw "Subnet ausente o prefijo distinto: $($vnet.Name)/$($networkParams[$key].value)" }
 }
}
Write-Step 'Comprobando SKU, imagen y cuotas vigentes'
$location = $vmParams.location.value
$size = $vmParams.vmSize.value
$skus = @(Get-AzComputeResourceSku -Location $location | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $size })
if ($skus.Count -ne 1) { throw "SKU $size no encontrada en $location. No se cambia la region de las redes." }
$sku = $skus[0]
if (@($sku.Restrictions | Where-Object Type -EQ 'Location').Count -gt 0) { throw "SKU $size restringida en $location. Seleccione otro tamano compatible; la cuota no garantiza disponibilidad." }
# Sin zonas solicitadas: un bloqueo solo zonal no equivale a bloqueo regional.
$capabilities = @{}
foreach ($capability in $sku.Capabilities) { $capabilities[$capability.Name] = $capability.Value }
$image = Get-AzVMImage -Location $location -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus $vmParams.windowsSku.value -Version latest
if ($null -eq $image) { throw 'Imagen Windows no disponible en esta region.' }
if ($capabilities.ContainsKey('CpuArchitectureType') -and $capabilities.CpuArchitectureType -ne 'x64') { throw 'La imagen requiere x64.' }
if ($capabilities.ContainsKey('HyperVGenerations') -and $image.HyperVGeneration -notin ($capabilities.HyperVGenerations -split ',')) { throw 'Generacion de imagen incompatible con SKU.' }
if ($vmParams.osDiskStorageAccountType.value -eq 'Premium_LRS' -and $capabilities.PremiumIO -ne 'True') { throw 'SKU sin soporte Premium_LRS.' }
# Conservador: calcular ambas VMs sin descontar maquinas existentes.
$requiredCores = 2 * [int]$capabilities.vCPUs
if ($requiredCores -le 0) { throw 'No fue posible determinar vCPU de la SKU.' }
$usage = @(Get-AzVMUsage -Location $location)
foreach ($quotaName in @('cores',$sku.Family)) {
 $quota = @($usage | Where-Object { $_.Name.Value -eq $quotaName })
 if ($quota.Count -ne 1 -or ([int]$quota[0].Limit - [int]$quota[0].CurrentValue) -lt $requiredCores) { throw "Cuota insuficiente o desconocida: $quotaName. Se requieren $requiredCores vCPU adicionales (estimacion conservadora)." }
}
if (-not $AdminPassword) { $AdminPassword = Read-Host 'Contrasena de administrador (solo en memoria)' -AsSecureString }
if ($AdminPassword.Length -lt 12) { throw 'La contrasena requiere al menos 12 caracteres.' }
$parameterObject = @{}
foreach ($key in $vmParams.Keys) { $parameterObject[$key] = $vmParams[$key].value }
$parameterObject.adminPassword = $AdminPassword
$arguments = @{ResourceGroupName=$ResourceGroupName;TemplateFile=$VmTemplateFile;TemplateParameterObject=$parameterObject;Mode='Incremental'}
Write-Step 'Validando computo con ARM y politicas vigentes'
Assert-ArmValidation -Arguments $arguments
if (-not $Deploy) { Write-Host 'Validacion completada. Sin cambios en Azure. Use -Deploy para desplegar computo.'; return }
Write-Step 'Desplegando las dos VMs en la red existente'
$deployment = New-AzResourceGroupDeployment @arguments -Name $VmDeploymentName
if ($deployment.ProvisioningState -ne 'Succeeded') { throw "Despliegue incompleto: $($deployment.ProvisioningState)" }
$deployment.Outputs | ConvertTo-Json -Depth 20
Write-Host 'Computo desplegado. La capacidad fisica solo se confirma durante el despliegue.'
