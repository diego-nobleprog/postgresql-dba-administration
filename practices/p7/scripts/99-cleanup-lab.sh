#!/bin/bash
source /tmp/p7-integrado-scripts/00-env.sh

for node in B A; do
    if [ -f "$R/$node/postmaster.pid" ]; then
        if [ "$node" = A ]; then port=5547; else port=5548; fi
        guard "$port" "$node"
    fi
    stop_cluster "$node"
done

echo 'POSTGRESQL A Y B DETENIDOS. DATOS Y EVIDENCIAS CONSERVADOS.'
