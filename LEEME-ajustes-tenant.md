# Ajustes al laboratorio ARM

Base revisada: diagnostico-lab-20261111-175755.json, del 11 de noviembre de 2026. Es una fotografia de la suscripcion Azure for Students, no una comprobacion vigente de todo el tenant.

## Cambios

| Componente | Configuracion adaptada |
|---|---|
| CoreServicesVnet y VMs | northcentralus |
| ManufacturingVnet | francecentral |
| ResearchVnet | spaincentral |
| Grupo existente | FCM-RG; conserva su ubicacion eastus |
| Red | Se genera lab-network-template.json desde JSONC; se conservan nombres, prefijos y subredes |
| Computo | Conserva dos VMs, Windows Server 2019 y StandardSSD_LRS |
| Tamano | Se conserva Standard_DS1_v2 pendiente de comprobacion en vivo |
| RDP | VirtualNetwork por defecto; se puede indicar una IPv4 publica /32 |
| Storage | Region parametrizable entre las cinco permitidas; HTTPS, TLS 1.2, sin acceso anonimo a blobs |

El script ahora reutiliza las tres redes existentes. No vuelve a aplicar sus subredes embebidas ni intenta mover redes entre regiones. La plantilla de red se conserva como referencia y para despliegues manuales revisados; el script no la despliega.

Las rutas se resuelven respecto del script. Valida contratos entre archivos, suscripcion activa, existencia de las redes, region, direccionamiento, subredes, restricciones regionales de SKU, imagen, arquitectura, generacion, soporte de disco Premium y cuotas regional/familia. Finalmente valida computo con ARM. Captura los objetos de error devueltos por Test-AzResourceGroupDeployment en vez de descartarlos.

## Limites del diagnostico

El diagnostico dice que no encontro los archivos: cantidadVM=0, parametros nulos y candidatos vacios. Los indicadores calculados de compatibilidad no permiten concluir que no exista ninguna VM desplegable. El catalogo si contiene restricciones explicitas; por ejemplo Standard_B2s y Standard_D2s_v3 estaban bloqueadas por ubicacion en northcentralus. No se eligen como alternativas automaticas.

Standard_DS1_v2 no aparece entre las alternativas evaluadas del diagnostico; se conserva sin afirmar que funciona. El script consulta su disponibilidad actual y se detiene si la SKU o las cuotas no son validas. No cambia automaticamente de region: la NIC y la VM deben corresponder con la red existente.

La cuota se estima para ambas VMs sin descontar VMs existentes. Esto puede detener una reejecucion aunque las VMs ya esten creadas; requiere revisar el inventario y el cambio previsto. La cuota y la validacion ARM tampoco reservan capacidad fisica ni garantizan exito del despliegue. La politica regional incluida es una referencia historica; ARM comprueba las politicas aplicables al despliegue de computo.

## Uso en Azure Cloud Shell (PowerShell)

Subir y descomprimir todos los archivos juntos. Si esta en Bash, ejecutar primero pwsh. Seleccionar la suscripcion:

```powershell
Set-AzContext -SubscriptionId '888b40f9-4bb8-49c3-8a68-377ce6a21fd2'
```

Validar sin crear ni modificar recursos (solicita contrasena solo si supera los controles previos):

```powershell
./deploy-lab-integral-cloudshell-commented.ps1
```

Desplegar computo despues de revisar la validacion:

```powershell
./deploy-lab-integral-cloudshell-commented.ps1 -Deploy
```

Para permitir RDP desde el equipo administrador, agregar a cualquiera de los dos comandos `-RdpAllowedSourceAddressPrefix 'TU_IPV4_PUBLICA/32'`, reemplazando el texto por la direccion real. Con VirtualNetwork no se habilita RDP directo desde Internet. La contrasena se solicita como SecureString y no se guarda en los archivos.

azuredeploy.json es una practica independiente de Storage y no se ejecuta desde el script. Su nombre de cuenta debe ser unico globalmente, entre 3 y 24 caracteres, solo letras minusculas y numeros. Validarlo antes de desplegarlo:

```powershell
Test-AzResourceGroupDeployment -ResourceGroupName FCM-RG -TemplateFile ./azuredeploy.json -storageAccountName 'NOMBRE_UNICO_VALIDO'
```

## Verificacion realizada

Sintaxis de PowerShell, lectura de todos los JSON/JSONC, igualdad entre la plantilla comentada de red y su JSON ejecutable, contratos de parametros y pruebas del flujo con respuestas simuladas de Azure. No se ha ejecutado ningun despliegue ni validacion autenticada contra Azure en esta revision.

## Referencias tecnicas

- https://learn.microsoft.com/powershell/module/az.resources/test-azresourcegroupdeployment
- https://learn.microsoft.com/powershell/module/az.compute/get-azcomputeresourcesku
- https://learn.microsoft.com/powershell/module/az.compute/get-azvmimage
- https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-resource-quota
