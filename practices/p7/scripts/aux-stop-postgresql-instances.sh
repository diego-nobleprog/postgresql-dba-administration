#!/bin/bash
# ======================================================================
# ARCHIVO: aux-stop-postgresql-instances.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Detener ordenadamente las instancias PostgreSQL A y B
# sin eliminar sus directorios de datos.
#
# Este archivo se utiliza durante operaciones de cierre
# y finalizacion del laboratorio.
#
# 1. CARGA DE CONFIGURACION
# ----------------------------------------------------------------------
# source incorpora las funciones compartidas.
#
# Se utilizan las rutas de datos, guard y stop_cluster.
#
# 2. ORDEN DE DETENCION
# ----------------------------------------------------------------------
# El bloque for recorre dos valores:
#
# Primero B.
# Despues A.
#
# El objetivo es solicitar la detencion de ambas instancias,
# independientemente de los roles que tengan en ese momento.
#
# 3. COMPROBACION DEL PROCESO
# ----------------------------------------------------------------------
# Se comprueba la existencia de:
#
# postmaster.pid
#
# Este archivo identifica una instancia PostgreSQL
# que tiene registrado su proceso principal.
#
# Cuando existe, se realizan comprobaciones adicionales.
#
# 4. IDENTIFICACION DEL PUERTO
# ----------------------------------------------------------------------
# Para PostgreSQL A se utiliza el puerto 5547.
#
# Para PostgreSQL B se utiliza el puerto 5548.
#
# 5. COMPROBACION DEL DIRECTORIO
# ----------------------------------------------------------------------
# guard consulta SHOW data_directory.
#
# El resultado debe coincidir con el directorio
# esperado de la instancia correspondiente.
#
# 6. DETENCION DEL SERVIDOR
# ----------------------------------------------------------------------
# stop_cluster solicita el apagado mediante pg_ctl.
#
# Se utiliza la modalidad fast.
#
# La funcion espera la terminacion del proceso
# y comprueba que desaparezca postmaster.pid.
#
# 7. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# PostgreSQL A detenido.
#
# PostgreSQL B detenido.
#
# Los directorios de datos permanecen disponibles.
#
# Los archivos de resultados no se eliminan.
#
# IMPORTANTE
# ----------------------------------------------------------------------
# Este script no elimina el contenedor Docker.
#
# Tampoco reconstruye las instancias ni borra las tablas.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-shared-environment-functions.sh
# 04-remove-docker-laboratory.ps1
#
# ======================================================================

source /tmp/p7-integrado-scripts/aux-shared-environment-functions.sh

for node in B A; do
    if [ -f "$R/$node/postmaster.pid" ]; then
        if [ "$node" = A ]; then port=5547; else port=5548; fi
        guard "$port" "$node"
    fi
    stop_cluster "$node"
done

echo 'POSTGRESQL A Y B DETENIDOS. DATOS Y EVIDENCIAS CONSERVADOS.'
