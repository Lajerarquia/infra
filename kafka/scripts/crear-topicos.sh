#!/usr/bin/env bash
# Crea o actualiza los tópicos de GymFlow (EP5) y muestra el estado de tópicos y consumer groups.
#
#   cd ~/gymflow/infra/kafka && ./scripts/crear-topicos.sh            # crear/actualizar + describir
#   cd ~/gymflow/infra/kafka && ./scripts/crear-topicos.sh describir  # solo describir (no cambia nada)
#
# Idempotente: se puede correr las veces que se quiera.
#   - Tópico inexistente → se crea con sus particiones, réplicas y configuraciones.
#   - Tópico existente   → se vuelven a aplicar sus configuraciones (kafka-configs --alter) y, si tiene MENOS
#                          particiones que las definidas, se aumentan. Nunca se reducen (Kafka no lo permite) y el
#                          factor de replicación no se cambia aquí (requiere una reasignación de particiones).
#
# Usa las herramientas que ya trae la imagen del broker (docker exec kafka1 ...): no hay que instalar nada en la EC2.
set -euo pipefail

BROKER="${BROKER_CONTAINER:-kafka1}"
BOOTSTRAP="kafka1:29092,kafka2:29092,kafka3:29092"
# Cada herramienta es una JVM aparte dentro del contenedor del broker: heap chico para no chocar con su mem_limit.
HEAP="-Xms16m -Xmx128m"

DIAS=86400000   # 1 día en milisegundos

# nombre | particiones | réplicas | configuraciones (separadas por espacio)
TOPICOS=(
  "reservations.events|3|3|cleanup.policy=delete retention.ms=$((7 * DIAS)) min.insync.replicas=2"
  "audit.timeline|3|3|cleanup.policy=compact,delete retention.ms=$((30 * DIAS)) min.insync.replicas=2 min.compaction.lag.ms=3600000"
  "reservations.events.gymflow-report.DLT|3|3|cleanup.policy=delete retention.ms=$((14 * DIAS)) min.insync.replicas=2"
  "audit.timeline.gymflow-audit.DLT|3|3|cleanup.policy=delete retention.ms=$((14 * DIAS)) min.insync.replicas=2"
)

kafka() {
  # $1 = herramienta (kafka-topics, kafka-configs, ...); el resto son sus argumentos.
  local herramienta="$1"; shift
  docker exec -e KAFKA_HEAP_OPTS="$HEAP" "$BROKER" "$herramienta" --bootstrap-server "$BOOTSTRAP" "$@"
}

esperar_brokers() {
  echo "==> Esperando a que los 3 brokers estén disponibles..."
  for intento in $(seq 1 30); do
    local n
    n=$(kafka kafka-broker-api-versions 2>/dev/null | grep -c '(id: ' || true)
    if [ "$n" -ge 3 ]; then
      echo "    $n brokers respondiendo."
      return 0
    fi
    echo "    $n/3 brokers (intento $intento/30), reintentando en 5 s..."
    sleep 5
  done
  echo "ERROR: no respondieron los 3 brokers. Revisa 'docker compose ps' y 'docker compose logs kafka1'." >&2
  exit 1
}

crear_o_actualizar() {
  local nombre="$1" particiones="$2" replicas="$3" configs="$4"
  local args_config=() lista_alter=()
  for c in $configs; do
    args_config+=(--config "$c")
    # kafka-configs separa los pares con comas: un valor que contiene comas (compact,delete) va entre corchetes.
    local clave="${c%%=*}" valor="${c#*=}"
    if [[ "$valor" == *,* ]]; then lista_alter+=("$clave=[$valor]"); else lista_alter+=("$c"); fi
  done

  echo "==> $nombre"
  if kafka kafka-topics --list | grep -qx "$nombre"; then
    echo "    ya existe: se aplican de nuevo sus configuraciones"
    local actuales
    actuales=$(kafka kafka-topics --describe --topic "$nombre" | grep -oE 'PartitionCount: ?[0-9]+' | grep -oE '[0-9]+')
    if [ "$actuales" -lt "$particiones" ]; then
      echo "    particiones $actuales → $particiones"
      kafka kafka-topics --alter --topic "$nombre" --partitions "$particiones"
    fi
    local unido
    unido=$(IFS=,; echo "${lista_alter[*]}")
    kafka kafka-configs --alter --entity-type topics --entity-name "$nombre" --add-config "$unido"
  else
    kafka kafka-topics --create --if-not-exists --topic "$nombre" \
      --partitions "$particiones" --replication-factor "$replicas" "${args_config[@]}"
  fi
}

describir() {
  echo
  echo "==================== TÓPICOS ===================="
  for t in "${TOPICOS[@]}"; do
    local nombre="${t%%|*}"
    echo
    kafka kafka-topics --describe --topic "$nombre"
    echo "-- configuraciones propias del tópico:"
    kafka kafka-configs --describe --entity-type topics --entity-name "$nombre"
  done
  echo
  echo "================ CONSUMER GROUPS ================"
  local grupos
  grupos=$(kafka kafka-consumer-groups --list 2>/dev/null || true)
  if [ -z "$grupos" ]; then
    echo "(todavía no hay consumer groups: aparecen cuando report y audit se conectan)"
  else
    # Por grupo: miembros, partición asignada, offset actual, último offset y LAG.
    kafka kafka-consumer-groups --describe --all-groups
  fi
}

if [ "${1:-}" != "describir" ]; then
  esperar_brokers
  for t in "${TOPICOS[@]}"; do
    IFS='|' read -r nombre particiones replicas configs <<< "$t"
    crear_o_actualizar "$nombre" "$particiones" "$replicas" "$configs"
  done
fi
describir
