\set ON_ERROR_STOP on

-- Datos iniciales del laboratorio.
-- Las claves son explicitas para facilitar la interpretacion.

CREATE SCHEMA backups;

CREATE TABLE backups.clientes (
    id integer PRIMARY KEY,
    nombre text NOT NULL
);

CREATE TABLE backups.pagos (
    id integer PRIMARY KEY,
    cliente_id integer NOT NULL REFERENCES backups.clientes(id),
    monto numeric(12,2) NOT NULL,
    estado text NOT NULL
);

INSERT INTO backups.clientes VALUES
(1, 'Cliente Norte'),
(2, 'Cliente Sur');

INSERT INTO backups.pagos VALUES
(101, 1, 100.00, 'CONFIRMADO'),
(102, 2, 250.00, 'CONFIRMADO'),
(103, 1, 300.00, 'CONFIRMADO');

-- El respaldo base debe partir de tres pagos.
SELECT id, cliente_id, monto, estado
FROM backups.pagos
ORDER BY id;