-- PRACTICA 03 - PREPARACION REPRODUCIBLE
-- Ejecutar en nobleprog_architecture_scenarios.
-- ADVERTENCIA: recrea las tablas del esquema operaciones.
-- No ejecutar sobre bases de datos productivas.

\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS operaciones;

DROP TABLE IF EXISTS operaciones.pedidos;
DROP TABLE IF EXISTS operaciones.productos;
DROP TABLE IF EXISTS operaciones.mvcc_demo;

CREATE TABLE operaciones.productos (
    id integer PRIMARY KEY,
    nombre text NOT NULL,
    precio numeric(12,2) NOT NULL,
    inventario integer NOT NULL
);

CREATE TABLE operaciones.pedidos (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    producto_id integer NOT NULL
        REFERENCES operaciones.productos(id),
    cantidad integer NOT NULL,
    total numeric(12,2) NOT NULL,
    creado_en timestamp NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE operaciones.mvcc_demo (
    id integer PRIMARY KEY,
    estado text NOT NULL
);

INSERT INTO operaciones.productos
SELECT
    g,
    'Producto ' || g,
    (g % 100 + 1)::numeric,
    1000
FROM generate_series(1,1000) AS g;

INSERT INTO operaciones.pedidos (
    producto_id, cantidad, total, creado_en
)
SELECT
    (g % 1000) + 1,
    (g % 5) + 1,
    ((g % 5000) + 1)::numeric / 2,
    clock_timestamp() - (g || ' minutes')::interval
FROM generate_series(1,50000) AS g;

INSERT INTO operaciones.mvcc_demo
VALUES (1,'ORIGINAL');

COMMIT;

ANALYZE operaciones.productos;
ANALYZE operaciones.pedidos;
ANALYZE operaciones.mvcc_demo;

SELECT
    (SELECT count(*) FROM operaciones.productos) AS productos,
    (SELECT count(*) FROM operaciones.pedidos) AS pedidos,
    (SELECT count(*) FROM operaciones.mvcc_demo) AS mvcc;

SELECT pg_size_pretty(
    pg_database_size(current_database())
) AS tamano_base;
