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

docker create --name $name --network none --cpus 2 --memory 4g --label nobleprog.p7.integrado=true --entrypoint /bin/bash postgresql-dba:18-p1 /tmp/p7-integrado-scripts/00-start-container.sh $Mode
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
