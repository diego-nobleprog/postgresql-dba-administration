# Utiliza Oracle Linux 9 como sistema operativo base del contenedor.
FROM oraclelinux:9

# Habilita el modulo de PostgreSQL 18 en los repositorios de Oracle Linux.
RUN dnf -y module enable postgresql:18

# Instala el cliente de PostgreSQL, incluyendo la herramienta psql.
RUN dnf -y install postgresql

# Instala el servidor PostgreSQL y sus herramientas de administracion.
RUN dnf -y install postgresql-server

# Instala las extensiones y utilidades adicionales de PostgreSQL.
RUN dnf -y install postgresql-contrib

# Limpia la cache del gestor de paquetes para reducir archivos innecesarios.
RUN dnf clean all

# Crea el directorio utilizado por PostgreSQL para sockets y archivos de bloqueo.
RUN mkdir -p /var/run/postgresql

# Asigna el directorio de sockets al usuario y grupo postgres.
RUN chown postgres:postgres /var/run/postgresql

# Establece permisos de lectura, escritura y acceso para propietario y grupo.
RUN chmod 775 /var/run/postgresql

# Define el directorio donde PostgreSQL almacenara los datos del cluster.
ENV PGDATA=/var/lib/pgsql/data

# Documenta que PostgreSQL utiliza el puerto TCP 5432 dentro del contenedor.
EXPOSE 5432

# Define Bash como comando predeterminado de la imagen; Compose iniciara PostgreSQL.
CMD ["/bin/bash"]
