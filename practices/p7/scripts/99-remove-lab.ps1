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
    docker exec -u postgres $Name bash /tmp/p7-integrado-scripts/99-cleanup-lab.sh
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
