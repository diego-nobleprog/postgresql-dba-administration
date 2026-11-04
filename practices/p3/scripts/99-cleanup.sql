-- PRACTICA 03 - LIMPIEZA FINAL
-- Ejecutar conectado a postgres, no a la base del lab.
-- Cierra las conexiones restantes y elimina SOLO
-- nobleprog_architecture_scenarios.
-- No ejecutar mientras los participantes trabajen.

\set ON_ERROR_STOP on

SELECT current_database() AS base_actual;

SELECT pid,usename,state
FROM pg_stat_activity
WHERE datname='nobleprog_architecture_scenarios';

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname='nobleprog_architecture_scenarios'
AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS nobleprog_architecture_scenarios;

SELECT count(*) AS bases_restantes_del_laboratorio
FROM pg_database
WHERE datname='nobleprog_architecture_scenarios';

-- El resultado final esperado es 0.
-- Los contadores globales y WAL historico no se revierten.
