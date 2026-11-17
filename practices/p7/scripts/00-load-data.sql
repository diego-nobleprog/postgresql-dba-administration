CREATE EXTENSION pg_stat_statements;
CREATE SCHEMA negocio;

CREATE TABLE negocio.clientes(
    id integer PRIMARY KEY,
    nombre text NOT NULL
);

CREATE TABLE negocio.pedidos(
    id integer PRIMARY KEY,
    cliente_id integer NOT NULL REFERENCES negocio.clientes(id),
    fecha date NOT NULL,
    estado text NOT NULL CHECK(estado IN ('PENDIENTE','PAGADO')),
    total numeric(12,2) NOT NULL CHECK(total>=0)
);

INSERT INTO negocio.clientes VALUES
(1,'Ana'),(2,'Luis'),(3,'Maria');

INSERT INTO negocio.pedidos VALUES
(101,1,'2026-01-15','PENDIENTE',200),
(102,2,'2026-01-15','PAGADO',500),
(103,1,'2026-01-15','PAGADO',150),
(104,3,'2026-01-15','PAGADO',250);

INSERT INTO negocio.pedidos
SELECT 1000+g,
       1+(g%3),
       DATE '2025-01-01'+(g%300),
       'PAGADO',
       10
FROM generate_series(1,50000) g;

ANALYZE negocio.clientes;
ANALYZE negocio.pedidos;
