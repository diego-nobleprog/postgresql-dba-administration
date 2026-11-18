#!/bin/bash
# ======================================================================
# ARCHIVO: 03-restore-initial-laboratory-state.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Reconstruir el laboratorio despues de completar los tres
# escenarios, recuperando sus datos y roles originales.
#
# La restauracion permite iniciar nuevamente la practica
# sin conservar las modificaciones realizadas durante los ejercicios.
#
# 1. CONFIGURACION INICIAL
# ----------------------------------------------------------------------
# Se cargan las variables y funciones compartidas.
#
# El script utiliza los directorios de PostgreSQL A y B,
# las funciones de consulta y las comprobaciones del laboratorio.
#
# 2. VERIFICACION DEL ESTADO FINAL
# ----------------------------------------------------------------------
# guard 5548 B comprueba la identidad de PostgreSQL B.
#
# pg_is_in_recovery() debe devolver false.
#
# Esto confirma que B fue promovido a PRIMARY.
#
# La consulta total_sql debe devolver 1500.
#
# Ese importe corresponde al resultado final del escenario 07.03.
#
# Si las condiciones no coinciden, no comienza la reconstruccion.
#
# 3. COMPROBACIONES DE SEGURIDAD
# ----------------------------------------------------------------------
# Se comprueba que A ya no tenga su archivo postmaster.pid.
#
# Tambien se verifica que no existan previamente:
#
# - A-ejecutado.
# - B-ejecutado.
#
# Estas comprobaciones evitan sobrescribir directorios
# conservados durante una restauracion anterior.
#
# 4. DETENCION DE POSTGRESQL B
# ----------------------------------------------------------------------
# stop_cluster B detiene ordenadamente el servidor promovido.
#
# En este momento B contiene los cambios del laboratorio,
# incluyendo el ultimo pedido y el indice experimental.
#
# 5. CONSERVACION DEL ESTADO EJECUTADO
# ----------------------------------------------------------------------
# Se renombran los directorios de datos:
#
# A pasa a A-ejecutado.
# B pasa a B-ejecutado.
#
# Estos directorios conservan el estado anterior
# a la reconstruccion.
#
# No se utilizan para continuar la nueva ejecucion.
#
# 6. RECONSTRUCCION DEL AMBIENTE
# ----------------------------------------------------------------------
# Se ejecuta:
#
# aux-configure-primary-and-standby.sh restaurado
#
# Este script crea nuevamente las instancias A y B.
#
# Tambien vuelve a cargar las tablas y registros originales,
# configura la replicacion y comprueba la sincronizacion.
#
# El argumento restaurado identifica esta preparacion
# como una reconstruccion posterior a los ejercicios.
#
# 7. VERIFICACIONES FINALES
# ----------------------------------------------------------------------
# Se comprueba que el indice experimental no exista en B.
#
# Tambien se valida que:
#
# - Existan cuatro pedidos de la fecha didactica.
# - No permanezcan sesiones identificadas como p7_sesion_%.
# - La preparacion haya recuperado los roles iniciales.
#
# El proceso de preparacion tambien comprueba el total
# original de 900 en ambas instancias.
#
# 8. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# PostgreSQL A vuelve a ser PRIMARY.
#
# PostgreSQL B vuelve a ser STANDBY.
#
# Los cuatro pedidos recientes recuperan su estado original.
#
# El importe total de pedidos pagados vuelve a ser 900.
#
# El indice experimental ya no existe.
#
# Las instancias permanecen funcionando para permitir
# una nueva ejecucion de los ejercicios.
#
# IMPORTANTE
# ----------------------------------------------------------------------
# Esta restauracion reconstruye las instancias.
#
# No es un procedimiento de pg_rewind ni una reincorporacion
# del antiguo principal mediante recuperacion incremental.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-shared-environment-functions.sh
# aux-configure-primary-and-standby.sh
# aux-create-tables-and-load-sample-data.sql
#
# ======================================================================

source /tmp/p7-integrado-scripts/aux-shared-environment-functions.sh

guard 5548 B
check 'B promovido' 5548 'SELECT pg_is_in_recovery()' f
check 'Total final antes de reconstruir' 5548 "$total_sql" 1500

test ! -f "$R/A/postmaster.pid"
test ! -e "$R/A-ejecutado"
test ! -e "$R/B-ejecutado"

stop_cluster B
mv "$R/A" "$R/A-ejecutado"
mv "$R/B" "$R/B-ejecutado"

bash "$S/aux-configure-primary-and-standby.sh" restaurado

check 'Indice experimental ausente en B' 5548 \
    "SELECT to_regclass('negocio.pedidos_estado_fecha_idx') IS NULL" t
check 'Cuatro pedidos recientes' 5547 \
    "SELECT count(*) FROM negocio.pedidos WHERE fecha=DATE '2026-01-15'" 4
check 'Sin sesiones del ejercicio' 5547 \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'p7_sesion_%'" 0

echo 'ESTADO INICIAL RECONSTRUIDO; A Y B SIGUEN ENCENDIDOS.'
