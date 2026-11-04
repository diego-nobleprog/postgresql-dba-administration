# Imagen independiente para demostrar una instalacion personalizada.
FROM oraclelinux:9

# Instalar compilador, herramientas y dependencias de PostgreSQL.
RUN dnf -y install gcc make tar gzip curl \
    readline-devel zlib-devel openssl-devel libicu-devel bison flex perl \
    && dnf clean all

# Definir la version y el directorio de instalacion personalizado.
ARG PG_VERSION=18.6
ENV PG_HOME=/opt/nobleprog/postgresql/18
ENV PGDATA=/data/nobleprog/instance01
ENV PATH=/opt/nobleprog/postgresql/18/bin:$PATH

# Descargar y compilar PostgreSQL desde codigo fuente.
RUN curl -fSL https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz \
    -o /tmp/postgresql.tar.gz \
    && mkdir -p /tmp/postgresql-src \
    && tar -xzf /tmp/postgresql.tar.gz -C /tmp/postgresql-src --strip-components=1 \
    && cd /tmp/postgresql-src \
    && ./configure --prefix=${PG_HOME} --with-openssl \
    && make -j2 \
    && make install \
    && rm -rf /tmp/postgresql-src /tmp/postgresql.tar.gz

# Crear un usuario independiente para ejecutar PostgreSQL.
RUN useradd -r -m -s /bin/bash postgres

# Preparar el directorio de datos personalizado.
RUN mkdir -p /data/nobleprog/instance01 \
    && chown -R postgres:postgres /data/nobleprog \
    && chmod 700 /data/nobleprog/instance01

# Preparar el directorio de sockets.
RUN mkdir -p /var/run/postgresql \
    && chown postgres:postgres /var/run/postgresql \
    && chmod 775 /var/run/postgresql

# Ejecutar PostgreSQL sin privilegios de root.
USER postgres

# Exponer el puerto interno de PostgreSQL.
EXPOSE 5432

# Mantener el arranque bajo control de Docker Compose.
CMD ["/bin/bash"]
