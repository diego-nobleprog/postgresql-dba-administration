-- PRACTICA 03 - CREACION DE BASE
-- Ejecutar conectado a la base postgres.
-- Esta operacion no elimina bases existentes.

SELECT current_database() AS base_actual;

SELECT datname
FROM pg_database
WHERE datname = 'nobleprog_architecture_scenarios';

SELECT format(
    'CREATE DATABASE %I',
    'nobleprog_architecture_scenarios'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = 'nobleprog_architecture_scenarios'
)
\gexec

SELECT datname, oid, dattablespace
FROM pg_database
WHERE datname = 'nobleprog_architecture_scenarios';
