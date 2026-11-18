<#
======================================================================
ARCHIVO: 04-remove-docker-laboratory.ps1
======================================================================

OBJETIVO
----------------------------------------------------------------------
Finalizar y eliminar de forma controlada el contenedor Docker
correspondiente al laboratorio integrado P7.

Este archivo representa el cierre definitivo del ambiente
cuando los participantes han terminado los ejercicios.

1. IDENTIFICACION DEL CONTENEDOR
----------------------------------------------------------------------
El parametro Name permite seleccionar:

- p7-integrado-lab.
- p7-integrado-validacion.

Si no se indica un nombre, se utiliza p7-integrado-lab.

No se aceptan otros nombres mediante este parametro.

2. COMPROBACION DE EXISTENCIA
----------------------------------------------------------------------
docker container ls -a obtiene los contenedores disponibles.

Se comprueba que exista el contenedor solicitado.

Si no existe, se detiene el procedimiento.

3. INSPECCION DE CONFIGURACION
----------------------------------------------------------------------
docker inspect recupera la configuracion del contenedor.

ConvertFrom-Json permite consultar sus propiedades
desde PowerShell.

Se comprueba la etiqueta:

nobleprog.p7.integrado=true

Esta etiqueta identifica el contenedor creado para P7.

4. VERIFICACION DE MONTAJES
----------------------------------------------------------------------
Se revisa la propiedad Mounts.

El script exige que no existan montajes externos.

Esto evita eliminar un contenedor cuya configuracion
no coincida con el ambiente aislado previsto.

5. COMPROBACION DEL ESTADO
----------------------------------------------------------------------
Solamente se aceptan dos estados:

- running: el contenedor sigue funcionando.
- exited: el contenedor ya termino su ejecucion.

Si Docker informa otro estado, el procedimiento se detiene.

6. DETENCION DE POSTGRESQL
----------------------------------------------------------------------
Si el contenedor esta funcionando, se ejecuta:

aux-stop-postgresql-instances.sh

Este archivo solicita la detencion de PostgreSQL A y B.

Si el cierre de las instancias falla, el contenedor
se conserva y la eliminacion no continua.

7. CONSERVACION DE RESULTADOS
----------------------------------------------------------------------
Se crea una carpeta dentro de temp.

El nombre incluye un identificador GUID para evitar
utilizar la misma carpeta en diferentes ejecuciones.

docker cp copia el directorio evidence del contenedor
hacia esa carpeta.

Si no se pueden recuperar los archivos, el contenedor
se conserva y la eliminacion se detiene.

8. ELIMINACION DEL CONTENEDOR
----------------------------------------------------------------------
docker rm -f elimina el contenedor seleccionado.

Posteriormente se vuelve a consultar Docker para
comprobar que ya no aparece en la lista de contenedores.

9. RESULTADO ESPERADO
----------------------------------------------------------------------
- PostgreSQL A y B detenidos.
- Contenedor seleccionado eliminado.
- Archivos de resultados recuperados.
- Repositorio del curso conservado.
- Otros laboratorios sin modificaciones.

IMPORTANTE
----------------------------------------------------------------------
La eliminacion del contenedor tambien elimina los datos
almacenados exclusivamente dentro de su sistema de archivos.

El script no elimina la imagen Docker del curso.

ARCHIVOS RELACIONADOS
----------------------------------------------------------------------
aux-stop-postgresql-instances.sh

======================================================================
#>

param(
    [ValidateSet("p7-integrado-lab","p7-integrado-validacion")]
    [string]$Name = "p7-integrado-lab"
)

$ErrorActionPreference = "Stop"
Set-Location "C:\Users\student\Desktop\postgresql-dba-administration"

$names = @(docker container ls -a --format '{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar Docker." }
if ($names -notcontains $Name) { throw "No existe $Name." }

$raw = @(docker inspect $Name)
if ($LASTEXITCODE -ne 0) { throw "No se pudo inspeccionar el contenedor." }
$info = @(($raw -join [Environment]::NewLine) | ConvertFrom-Json)[0]

if ($info.Config.Labels.'nobleprog.p7.integrado' -ne "true") {
    throw "La etiqueta no corresponde al laboratorio."
}

$mounts = @($info.Mounts | Where-Object { $null -ne $_ })
if ($mounts.Count -gt 0) {
    throw "Hay montajes. Revisar origen y destino antes de eliminar."
}

if ($info.State.Status -notin @("running","exited")) {
    throw "Estado inesperado: $($info.State.Status)."
}

if ($info.State.Status -eq "running") {
    docker exec -u postgres $Name bash /tmp/p7-integrado-scripts/aux-stop-postgresql-instances.sh
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo el cierre. El contenedor se conserva."
    }
}

$folder = Join-Path (Get-Location).Path ("temp\p7-cierre-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $folder -Force | Out-Null

docker cp "${Name}:/tmp/nobleprog-p7-integrado/evidence" $folder
if ($LASTEXITCODE -ne 0) {
    throw "No se recuperaron las evidencias. El contenedor se conserva."
}

docker rm -f $Name
if ($LASTEXITCODE -ne 0) { throw "No se pudo eliminar el contenedor." }

$remaining = @(docker container ls -a --format '{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw "No se pudo verificar la eliminacion." }
if ($remaining -contains $Name) { throw "El contenedor sigue existiendo." }

Write-Output "CONTENEDOR ELIMINADO: $Name"
Write-Output "Evidencias conservadas: $folder"
Write-Output "Los archivos del curso y los otros laboratorios permanecen intactos."
