#!/bin/bash
source /tmp/p7-integrado-scripts/00-env.sh

guard 5547 A
guard 5548 B
check 'B todavia standby' 5548 'SELECT pg_is_in_recovery()' t
sync_replica
