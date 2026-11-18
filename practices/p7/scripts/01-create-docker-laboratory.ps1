<#
======================================================================
ARCHIVO: 01-create-docker-laboratory.ps1
======================================================================

OBJETIVO
----------------------------------------------------------------------
Crear el laboratorio integrado de Performance Tuning y Replicacion,
utilizando Docker Desktop y dos instancias PostgreSQL.

Este archivo es el punto de entrada desde PowerShell.
Prepara el ambiente necesario para ejecutar los tres escenarios.

1. PARAMETROS DE EJECUCION
----------------------------------------------------------------------
El parametro Mode permite seleccionar dos modalidades:

- manual: prepara el ambiente para realizar los ejercicios.
- validate: ejecuta las verificaciones automatizadas.

Si no se especifica Mode, se utiliza manual.

ErrorActionPreference = Stop permite detener el script cuando
PowerShell encuentra un error que puede terminar la ejecucion.

2. COMPROBACION DEL REPOSITORIO
----------------------------------------------------------------------
Set-Location establece la raiz del repositorio del curso.

git branch --show-current obtiene la rama activa.

Se exige la rama p7 para evitar preparar el laboratorio
utilizando archivos de otra practica.

Si Git falla o la rama no corresponde, se detiene la ejecucion.

3. IDENTIFICACION DEL CONTENEDOR
----------------------------------------------------------------------
El nombre depende de la modalidad:

- manual: p7-integrado-lab.
- validate: p7-integrado-validacion.

docker container ls -a consulta los contenedores existentes.

Si ya existe uno con el nombre seleccionado, se detiene
la ejecucion para evitar sobrescribir ese ambiente.

4. COMPROBACION DE LA IMAGEN DOCKER
----------------------------------------------------------------------
docker image inspect verifica la existencia de:

postgresql-dba:18-p1

Esta imagen proporciona Oracle Linux 9 y PostgreSQL 18,
junto con las herramientas necesarias para los ejercicios.

El script no construye ni descarga la imagen.
La imagen debe encontrarse disponible previamente.

5. CREACION DEL CONTENEDOR
----------------------------------------------------------------------
docker create define las caracteristicas del ambiente:

- --name: asigna el nombre del contenedor.
- --network none: deshabilita la red externa del contenedor.
- --cpus 2: limita el uso a dos CPU.
- --memory 4g: establece un limite de memoria de 4 GB.
- --label: identifica el contenedor como parte de P7.
- --entrypoint /bin/bash: inicia el script Bash indicado.

El contenedor ejecutara:

aux-initialize-docker-container.sh

Ese archivo se encarga de preparar PostgreSQL internamente.

6. VERIFICACION DE AISLAMIENTO
----------------------------------------------------------------------
docker inspect obtiene la configuracion real del contenedor.

Se comprueba que:

- No existan montajes externos inesperados.
- La configuracion de red sea none.

Estas condiciones permiten mantener los datos de P7
separados de los archivos y servicios externos.

7. COPIA DE ARCHIVOS E INICIO
----------------------------------------------------------------------
docker cp copia la carpeta scripts al contenedor.

Destino interno:

/tmp/p7-integrado-scripts

docker start inicia el contenedor y ejecuta su entrypoint.

A partir de este momento comienza la preparacion de
PostgreSQL A y PostgreSQL B.

8. VERIFICACION EN MODALIDAD MANUAL
----------------------------------------------------------------------
El script consulta docker logs repetidamente.

Busca el mensaje:

LABORATORIO INTEGRADO PREPARADO; EJERCICIOS SIN EJECUTAR.

Se realizan hasta 120 comprobaciones, separadas por un segundo.

Si el contenedor termina antes de completar la preparacion,
o no aparece el mensaje esperado, se informa un error.

Posteriormente se comprueba mediante pg_ctl que:

- PostgreSQL A este funcionando.
- PostgreSQL B este funcionando.

El script no se limita a comprobar que Docker este encendido:
tambien verifica los procesos de ambas instancias.

9. VERIFICACION EN MODALIDAD VALIDATE
----------------------------------------------------------------------
docker wait espera la terminacion de la validacion automatizada.

Se recuperan los logs de ejecucion y los resultados generados.

Se crea una carpeta identificada con un GUID dentro de temp
para conservar los resultados de esa ejecucion.

Se comprueba la existencia del archivo de resumen.

El codigo de salida debe ser 0 para considerar que
la ejecucion automatizada termino correctamente.

10. RESULTADO ESPERADO
----------------------------------------------------------------------
En modalidad manual:

- Contenedor p7-integrado-lab disponible.
- PostgreSQL A funcionando como PRIMARY.
- PostgreSQL B funcionando como STANDBY.
- Tablas y registros iniciales preparados.
- Replicacion fisica configurada.
- Ejercicios disponibles para los participantes.

El script no ejecuta los escenarios didacticos en modo manual.

ARCHIVOS RELACIONADOS
----------------------------------------------------------------------
aux-initialize-docker-container.sh
aux-configure-primary-and-standby.sh
aux-create-tables-and-load-sample-data.sql
aux-validate-integrated-laboratory.sh

======================================================================
#>

param(
    [ValidateSet("manual","validate")]
    [string]$Mode = "manual"
)

$ErrorActionPreference = "Stop"
Set-Location "C:\Users\student\Desktop\postgresql-dba-administration"

$branch = git branch --show-current
if ($LASTEXITCODE -ne 0 -or $branch -ne "p7") {
    throw "Debes estar en p7."
}

if ($Mode -eq "manual") {
    $name = "p7-integrado-lab"
} else {
    $name = "p7-integrado-validacion"
}

$names = @(docker container ls -a --format '{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar Docker." }
if ($names -contains $name) { throw "$name ya existe. No se sobrescribira." }

docker image inspect postgresql-dba:18-p1 --format '{{.Id}}'
if ($LASTEXITCODE -ne 0) { throw "No esta disponible la imagen." }

docker create --name $name --network none --cpus 2 --memory 4g --label nobleprog.p7.integrado=true --entrypoint /bin/bash postgresql-dba:18-p1 /tmp/p7-integrado-scripts/aux-initialize-docker-container.sh $Mode
if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el contenedor." }

$raw = @(docker inspect $name)
if ($LASTEXITCODE -ne 0) { throw "No se pudo inspeccionar el contenedor." }
$info = @(($raw -join [Environment]::NewLine) | ConvertFrom-Json)[0]
$mounts = @($info.Mounts | Where-Object { $null -ne $_ })
if ($mounts.Count -gt 0) { throw "Hay montajes inesperados. No se iniciara." }
if ($info.HostConfig.NetworkMode -ne "none") {
    throw "La red no corresponde al laboratorio aislado."
}

docker cp ".\practices\p7\scripts" "${name}:/tmp/p7-integrado-scripts"
if ($LASTEXITCODE -ne 0) { throw "No se pudieron copiar los scripts." }

docker start $name
if ($LASTEXITCODE -ne 0) { throw "No se pudo iniciar el contenedor." }

if ($Mode -eq "manual") {
    $ready = $false
    for ($attempt = 1; $attempt -le 120; $attempt++) {
        $logs = @(docker logs $name)
        if ($LASTEXITCODE -ne 0) { throw "No se pudieron consultar los logs." }

        if ($logs -contains "LABORATORIO INTEGRADO PREPARADO; EJERCICIOS SIN EJECUTAR.") {
            $ready = $true
            break
        }

        $state = docker inspect $name --format '{{.State.Status}}'
        if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar el estado." }
        if ($state -eq "exited") { break }
        Start-Sleep -Seconds 1
    }

    docker logs $name
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron recuperar los logs." }
    if (-not $ready) { throw "No se confirmo la preparacion. No repitas el bloque." }

    docker exec -u postgres $name pg_ctl -D /tmp/nobleprog-p7-integrado/A status
    if ($LASTEXITCODE -ne 0) { throw "A no esta disponible." }
    docker exec -u postgres $name pg_ctl -D /tmp/nobleprog-p7-integrado/B status
    if ($LASTEXITCODE -ne 0) { throw "B no esta disponible." }

    Write-Output "LISTO PARA CLASE: CARGA INICIAL PRESENTE; EJERCICIOS SIN EJECUTAR."
    return
}

Write-Output "VALIDACION EN CURSO. Puede tardar varios minutos."
$waitOutput = @(docker wait $name)
if ($LASTEXITCODE -ne 0) { throw "No se pudo esperar el resultado." }
$runCode = ($waitOutput -join "").Trim()

$folder = Join-Path (Get-Location).Path ("temp\p7-definitivo-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

$logs = @(docker logs $name)
if ($LASTEXITCODE -ne 0) { throw "No se pudieron recuperar los logs." }
[System.IO.File]::WriteAllLines((Join-Path $folder "resultados-completos.txt"),[string[]]$logs,$utf8)
$logs | ForEach-Object { Write-Output $_ }

docker cp "${name}:/tmp/nobleprog-p7-integrado/evidence" $folder
if ($LASTEXITCODE -ne 0) { throw "No se recuperaron todas las evidencias." }

$summary = Join-Path $folder "evidence\resumen.txt"
if (-not (Test-Path -LiteralPath $summary)) { throw "No se genero resumen." }

Write-Output "=== RESUMEN ==="
Get-Content -LiteralPath $summary
Write-Output "Evidencias: $folder"

if ($runCode -ne "0") { throw "Validacion fallida. No repitas: comparte la salida." }
Write-Output "VALIDACION TERMINADA; PENDIENTE DE REVISION."
