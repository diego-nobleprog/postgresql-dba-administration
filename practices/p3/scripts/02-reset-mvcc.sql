-- PRACTICA 03.3 - RESTAURACION DEL ESCENARIO MVCC
-- Ejecutar sin transacciones de demostracion abiertas.

\set ON_ERROR_STOP on

BEGIN;

DELETE FROM operaciones.mvcc_demo;

INSERT INTO operaciones.mvcc_demo(id,estado)
VALUES (1,'ORIGINAL');

COMMIT;

ANALYZE operaciones.mvcc_demo;

SELECT id,estado,xmin,xmax,ctid
FROM operaciones.mvcc_demo;

-- IMPORTANTE:
-- xmin y ctid no tienen por que coincidir con la
-- primera ejecucion. Son identificadores internos.
