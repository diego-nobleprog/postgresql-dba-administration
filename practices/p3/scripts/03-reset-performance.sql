-- PRACTICA 03.2 - RESTAURACION DEL ESCENARIO
-- Recupera la poblacion inicial y elimina el indice
-- adicional de la demostracion.
-- Ejecutar sin otras sesiones modificando estas tablas.

\set ON_ERROR_STOP on

BEGIN;

DROP TABLE IF EXISTS operaciones.pedidos;

CREATE TABLE operaciones.pedidos (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    producto_id integer NOT NULL
        REFERENCES operaciones.productos(id),
    cantidad integer NOT NULL,
    total numeric(12,2) NOT NULL,
    creado_en timestamp NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO operaciones.pedidos (
    producto_id,cantidad,total,creado_en
)
SELECT
    (g % 1000) + 1,
    (g % 5) + 1,
    ((g % 5000) + 1)::numeric / 2,
    clock_timestamp() - (g || ' minutes')::interval
FROM generate_series(1,50000) AS g;

UPDATE operaciones.productos
SET inventario = 1000;

COMMIT;

ANALYZE operaciones.productos;
ANALYZE operaciones.pedidos;

SELECT count(*) AS pedidos
FROM operaciones.pedidos;

SELECT count(*) AS productos
FROM operaciones.productos;

SELECT count(*) AS inventario_incorrecto
FROM operaciones.productos
WHERE inventario <> 1000;

SELECT indexname
FROM pg_indexes
WHERE schemaname='operaciones'
AND tablename='pedidos'
ORDER BY indexname;
