#!/bin/bash
# ======================================================================
# ARCHIVO: aux-initialize-docker-container.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Inicializar el contenedor Docker que contiene el laboratorio
# integrado de Performance Tuning y Replicacion de PostgreSQL.
#
# Este script se ejecuta automaticamente al iniciar el contenedor.
# Su responsabilidad es comprobar las condiciones del ambiente
# y preparar las instancias antes de comenzar los ejercicios.
#
# No es necesario ejecutarlo manualmente desde PowerShell.
#
# 1. CONFIGURACION INICIAL DE BASH
# ----------------------------------------------------------------------
# set -Eeuo pipefail habilita comprobaciones de errores.
#
# - set -e: detiene la ejecucion cuando un comando falla,
#   salvo las excepciones propias del control de flujo.
# - set -E: permite heredar manejadores ERR, si estan definidos.
# - set -u: impide utilizar variables no definidas.
# - pipefail: detecta errores dentro de pipelines.
#
# exec 2>&1 dirige stderr hacia stdout.
#
# Esto permite observar juntos los mensajes y errores.
#
# PATH establece los directorios donde se buscan
# las herramientas del sistema Linux.
#
# 2. DIRECTORIOS DE TRABAJO
# ----------------------------------------------------------------------
# R=/tmp/nobleprog-p7-integrado
#
# Directorio donde se preparan los recursos del laboratorio,
# incluidos los directorios de datos de PostgreSQL.
#
# S=/tmp/p7-integrado-scripts
#
# Directorio donde se encuentran los scripts copiados
# desde el repositorio hacia el contenedor.
#
# 3. SELECCION DEL MODO
# ----------------------------------------------------------------------
# MODE obtiene el primer argumento recibido.
#
# Si no existe un argumento, se utiliza manual.
#
# Se aceptan dos modalidades:
#
# manual:
# Prepara las instancias para ejecutar los ejercicios.
#
# validate:
# Ejecuta las comprobaciones automatizadas.
#
# El bloque case rechaza cualquier otro valor.
#
# 4. COMPROBACIONES PREVIAS
# ----------------------------------------------------------------------
# id -u permite comprobar que el usuario actual sea root.
#
# El script requiere permisos para crear directorios
# y asignar su propiedad al usuario postgres.
#
# Tambien se comprueba que R no exista previamente.
#
# Esta condicion evita reutilizar un directorio de trabajo
# que ya se encuentra presente.
#
# 5. VALIDACION DE SINTAXIS BASH
# ----------------------------------------------------------------------
# El bloque for recorre los archivos .sh de S.
#
# Para cada archivo se ejecuta bash -n.
#
# Esta operacion analiza la sintaxis Bash sin ejecutar
# las instrucciones del archivo.
#
# Por ejemplo, permite detectar estructuras if incompletas
# o errores de sintaxis antes de comenzar la preparacion.
#
# No comprueba el funcionamiento completo de cada script.
#
# 6. CREACION DEL DIRECTORIO
# ----------------------------------------------------------------------
# mkdir -p crea el directorio R.
#
# chown postgres:postgres asigna el directorio
# al usuario y grupo postgres.
#
# Esto permite ejecutar posteriormente las operaciones
# de PostgreSQL utilizando ese usuario.
#
# 7. MODALIDAD VALIDATE
# ----------------------------------------------------------------------
# Si MODE es validate, se ejecuta:
#
# aux-validate-integrated-laboratory.sh
#
# runuser cambia del usuario root al usuario postgres.
#
# timeout establece un limite de 600 segundos.
#
# Si se supera ese limite, envia SIGTERM.
#
# Si el proceso no termina despues de otros 30 segundos,
# puede finalizarse mediante SIGKILL.
#
# exec sustituye el proceso actual por la validacion.
#
# Esta modalidad no continua hacia la preparacion manual.
#
# 8. MODALIDAD MANUAL
# ----------------------------------------------------------------------
# Si MODE es manual, runuser ejecuta:
#
# aux-configure-primary-and-standby.sh
#
# Este archivo prepara PostgreSQL A y B, carga los datos
# y establece la replicacion fisica.
#
# Si la preparacion falla, se intenta ejecutar:
#
# aux-stop-postgresql-instances.sh
#
# El objetivo es detener las instancias antes de finalizar
# con un codigo de error.
#
# 9. FINALIZACION CORRECTA
# ----------------------------------------------------------------------
# Cuando termina la preparacion se muestra:
#
# LABORATORIO INTEGRADO PREPARADO; EJERCICIOS SIN EJECUTAR.
#
# Posteriormente se ejecuta:
#
# exec sleep infinity
#
# Esta operacion mantiene activo el proceso principal
# del contenedor Docker.
#
# Las instancias PostgreSQL continuan funcionando
# como procesos independientes dentro del contenedor.
#
# 10. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# - Contenedor activo.
# - PostgreSQL A funcionando como PRIMARY.
# - PostgreSQL B funcionando como STANDBY.
# - Datos iniciales preparados.
# - Replicacion fisica configurada.
# - Escenario 07.01 disponible para comenzar.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-configure-primary-and-standby.sh
# aux-stop-postgresql-instances.sh
# aux-validate-integrated-laboratory.sh
#
# ======================================================================

set -Eeuo pipefail
exec 2>&1
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

R=/tmp/nobleprog-p7-integrado
S=/tmp/p7-integrado-scripts
MODE=${1:-manual}

case "$MODE" in manual|validate) ;; *) exit 1;; esac

test "$(id -u)" -eq 0
test ! -e "$R"

for file in "$S"/*.sh; do
    bash -n "$file"
done

mkdir -p "$R"
chown postgres:postgres "$R"

if [ "$MODE" = validate ]; then
    exec /usr/sbin/runuser -u postgres -- \
        timeout --signal=TERM --kill-after=30s 600 \
        bash "$S/aux-validate-integrated-laboratory.sh"
fi

if ! /usr/sbin/runuser -u postgres -- \
    bash "$S/aux-configure-primary-and-standby.sh"; then
    /usr/sbin/runuser -u postgres -- \
        bash "$S/aux-stop-postgresql-instances.sh" || exit 1
    exit 1
fi

echo 'LABORATORIO INTEGRADO PREPARADO; EJERCICIOS SIN EJECUTAR.'
exec sleep infinity
