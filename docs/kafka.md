# Kafka de GymFlow en AWS (EP5)

Kafka **complementa** a RabbitMQ: RabbitMQ sigue con los comandos/tareas (notify) y Kafka transporta los **eventos** de
analítica (report) y auditoría (audit). Nada de lo de RabbitMQ cambia.

| EC2 | Qué corre | Compose |
|---|---|---|
| `ec2-apps` (ya existe) | bff, catalog, reservations, notify, mq-admin y, desde la EP5, report, audit y kafka-admin | `infra/apps/compose.yml` |
| `ec2-mq` (ya existe) | RabbitMQ 3.13, clúster de 2 nodos | `infra/mq/compose.yml` |
| `ec2-kafka` (nueva) | 3 ZooKeeper + 3 brokers Kafka (Confluent Platform 7.9) + Kafka UI | `infra/kafka/compose.yml` |

```
ec2-apps (gymflow-apps-sg)                         ec2-kafka (gymflow-kafka-sg)        red Docker "gymflow-kafka"
  reservations ─┐                                    kafka1 :9092 ┐                    zookeeper1 ┐
  catalog      ─┼─ producen / consumen ───────────>  kafka2 :9093 ├─ INTERNAL :29092 ─ zookeeper2 ├ ensemble (2181/2888/3888,
  report       ─┤   (IP privada, 9092-9094)          kafka3 :9094 ┘                    zookeeper3 ┘  no publicados)
  audit        ─┤                                    kafka-ui :8080 ── INTERNAL ──> kafka1..3
  kafka-admin  ─┘
tu PC ──HTTP 8080 (solo tu IP)──────────────────>  Kafka UI
consola AWS ──EC2 Instance Connect (SSH 22)─────>  ec2-kafka
```

## Topología

| Tópico | Part. | Réplicas | `cleanup.policy` | `retention.ms` | Otros | Productores → consumidores (grupo) |
|---|---|---|---|---|---|---|
| `reservations.events` | 3 | 3 | `delete` | 604800000 (7 días) | `min.insync.replicas=2` | reservations → report (`gymflow-report`) |
| `audit.timeline` | 3 | 3 | `compact,delete` | 2592000000 (30 días) | `min.insync.replicas=2`, `min.compaction.lag.ms=3600000` | reservations, catalog → audit (`gymflow-audit`) |
| `reservations.events.gymflow-report.DLT` | 3 | 3 | `delete` | 1209600000 (14 días) | `min.insync.replicas=2` | errores de report |
| `audit.timeline.gymflow-audit.DLT` | 3 | 3 | `delete` | 1209600000 (14 días) | `min.insync.replicas=2` | errores de audit |

Por qué cada parámetro:

- **3 particiones**: hasta 3 consumidores de un mismo grupo trabajan en paralelo (un hilo por partición). Con más
  particiones que consumidores no se gana nada en este volumen; con menos, sobrarían hilos.
- **3 réplicas + `min.insync.replicas=2`**: con `acks=all` el productor recibe OK cuando al menos 2 réplicas tienen el
  mensaje. Si cae 1 broker se sigue escribiendo; si caen 2, Kafka **rechaza** la escritura (`NOT_ENOUGH_REPLICAS`) en vez
  de aceptar algo que podría perderse.
- **`reservations.events` → `delete` 7 días**: son hechos para analítica; report los guarda en su BD apenas llegan.
  7 días alcanzan para re-procesar (reset de offsets) si report tuvo un error.
- **`audit.timeline` → `compact,delete` 30 días**: la clave es el `eventId`. La compactación elimina solo duplicados
  del mismo evento (reintentos del productor, replays) y nunca borra historia distinta; `delete` igual limpia a los
  30 días (la historia definitiva queda en la BD de audit). `min.compaction.lag.ms=1 h`: un mensaje recién escrito no
  se compacta antes de una hora, así audit alcanza a leerlo aunque llegue un duplicado.
- **DLT 14 días**: más que el tópico principal, para tener tiempo de revisar y reprocesar los mensajes que fallaron.

## Decisiones del `compose.yml`

- **Confluent Platform 7.9** (`cp-zookeeper` y `cp-kafka` 7.9.10, Apache Kafka 3.9). Es la **última línea con ZooKeeper**:
  Kafka 4.x / cp 8.x solo funcionan en modo KRaft, y la pauta pide un compose con ZooKeeper + brokers.
- **3 ZooKeeper**: el quórum es la mayoría (2 de 3), así que se tolera la caída de 1 nodo. Con 2 nodos el quórum
  también sería 2 y no se toleraría ninguna caída.
- **3 brokers**: el mínimo para replicar 3 veces y seguir escribiendo con uno caído.
- **Dos listeners**:
  - `INTERNAL` (`kafkaN:29092`): tráfico entre brokers y de Kafka UI, dentro de la red de Docker.
  - `EXTERNAL` (`${KAFKA_ADVERTISED_HOST}:9092|9093|9094`): para los microservicios de `ec2-apps`. Cada broker usa un
    puerto distinto porque todos comparten la IP de la EC2. El cliente se conecta primero a cualquiera y después a la
    dirección **que cada broker anuncia**; por eso `KAFKA_ADVERTISED_HOST` debe ser la **IP privada** de `ec2-kafka`
    (en local, `localhost`).
- **`auto.create.topics.enable=false`**: un productor o consumidor con un nombre mal escrito recibe un error, en vez de
  crear un tópico nuevo con la configuración por defecto. Los tópicos se crean solo con `scripts/crear-topicos.sh`,
  kafka-admin o los `NewTopic` de los servicios.
- **Defaults del clúster** `default.replication.factor=3`, `num.partitions=3`, `min.insync.replicas=2` y los tópicos
  internos (`__consumer_offsets`, transacciones) también con 3 réplicas: si alguien crea un tópico sin indicar nada,
  igual queda replicado. `unclean.leader.election.enable=false`: nunca se elige como líder una réplica atrasada.
- **Healthchecks**:
  - ZooKeeper: el comando `srvr` responde `Mode: leader|follower` solo si el nodo está en el quórum.
  - Brokers: `kafka-broker-api-versions` contra el propio broker (responde solo cuando ya está registrado y atiende
    solicitudes). Es otra JVM, así que se lanza con heap de 64 MB y cada 30 s, para no gastar memoria ni CPU.
  - Kafka UI: `/actuator/health`.
  - `depends_on: service_healthy`: los brokers arrancan cuando los 3 ZooKeeper están en quórum; Kafka UI cuando los 3
    brokers están sanos.
- **Volúmenes con nombre** para datos de ZooKeeper y Kafka: sobreviven a `docker compose down` (se borran solo con `down -v`).
- **Memoria** (t3.medium, 4 GB). Límites: ZooKeeper 320 MB ×3, brokers 768 MB ×3, Kafka UI 384 MB → 3,6 GB como **techo**.
  Heap: ZooKeeper `-Xms64m -Xmx256m`, brokers `-Xms256m -Xmx512m`. El `-Xms` bajo hace que el heap crezca solo si hace falta;
  en reposo el total ronda 2,5 GB. Al broker se le dejan ~250 MB fuera del heap (metaspace, hilos, buffers de red).
  Medido en local con los 4 tópicos creados: ZooKeeper ~80 MB c/u, brokers ~370-400 MB c/u, Kafka UI ~280 MB → **~1,7 GB**.
- **Kafka UI** (`kafbat/kafka-ui`, fork mantenido de `provectuslabs/kafka-ui`) con **login** (`AUTH_TYPE=LOGIN_FORM`): el
  puerto 8080 solo se abre a la IP del equipo, pero igual se protege. `DYNAMIC_CONFIG_ENABLED=false`: la configuración
  del clúster está en el compose y no se cambia desde la UI.

---

## Parte A — Crear `ec2-kafka` en el Learner Lab

Antes: **Start Lab**, esperar el círculo verde y abrir la consola de AWS (región **us-east-1**).

### A1. Security group `gymflow-kafka-sg`

EC2 → **Security Groups** → **Create security group**:

- Name: `gymflow-kafka-sg` · Description: `Kafka de GymFlow` · VPC: la **misma VPC de `ec2-apps`**.
- **Inbound rules**:

| Type | Port range | Source | Para qué |
|---|---|---|---|
| Custom TCP | `9092-9094` | Custom → `gymflow-apps-sg` | Los 3 brokers (listener EXTERNAL) para los microservicios |
| Custom TCP | `8080` | My IP | Kafka UI desde tu navegador |
| SSH | `22` | Anywhere-IPv4 (`0.0.0.0/0`) | EC2 Instance Connect (se conecta desde IP de AWS, no desde tu PC) |

- Outbound: la regla por defecto. **Create security group**.

No se abren 2181/2888/3888 (ZooKeeper) ni 29092 (INTERNAL): solo se usan dentro de la red Docker de `ec2-kafka`.
Si cambias de red (casa / Duoc), edita la regla "My IP" del 8080.

### A2. Lanzar la instancia

EC2 → **Instances** → **Launch instances**:

| Campo | Valor |
|---|---|
| Name | `ec2-kafka` |
| AMI | **Amazon Linux 2023** (64-bit x86) |
| Instance type | **t3.medium** (4 GB) |
| Key pair | `vockey` |
| Network settings → Edit | VPC: la misma de `ec2-apps` · Auto-assign public IP: Enable · **Select existing security group: `gymflow-kafka-sg`** |
| Storage | **16 GiB** gp3: imágenes de Confluent (~1 GB cada una) + logs de Kafka con 3 réplicas |

**Launch instance** y esperar **Running** y checks **2/2**. Anota la **IP privada** (Details → *Private IPv4 address*):
no cambia al detener e iniciar la instancia y es la que va en `KAFKA_ADVERTISED_HOST`.

### A3. IP elástica

EC2 → **Elastic IPs** → **Allocate Elastic IP address** → Allocate → **Actions → Associate Elastic IP address** →
Instance: `ec2-kafka` → **Associate**. Es la IP para Kafka UI (`http://<ip-elastica-ec2-kafka>:8080`).

### A4. Preparar `ec2-kafka` (Docker, Compose y git)

Igual que `ec2-mq` ([rabbitmq.md](rabbitmq.md), A4): **Connect → EC2 Instance Connect → `ec2-user`** y:

```bash
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
exit                                        # vuelve a conectarte para que tome el grupo docker
```

---

## Parte B — Levantar Kafka en `ec2-kafka`

```bash
mkdir -p ~/gymflow && cd ~/gymflow
git clone https://github.com/Lajerarquia/infra.git
cd ~/gymflow/infra/kafka
cp .env.example .env && chmod 600 .env
nano .env
#   KAFKA_ADVERTISED_HOST=<ip-privada-ec2-kafka>      (p. ej. 172.31.x.x; NO la elástica)
#   KAFKA_UI_USER=gymflow
#   KAFKA_UI_PASSWORD=<contraseña nueva>
docker compose up -d
docker compose ps        # zookeeper1..3 y kafka1..3 "healthy" (~1-2 min), luego kafka-ui
```

Verificar:

```bash
for z in zookeeper1 zookeeper2 zookeeper3; do
  docker exec $z bash -c 'exec 3<>/dev/tcp/localhost/2181; echo srvr >&3; cat <&3' | grep Mode   # 1 leader y 2 follower
done
docker exec -e KAFKA_HEAP_OPTS=-Xmx128m kafka1 kafka-broker-api-versions --bootstrap-server kafka1:29092 | grep 'id:'
#   kafka1:29092 (id: 1 ...)  kafka2:29092 (id: 2 ...)  kafka3:29092 (id: 3 ...)
docker stats --no-stream   # memoria por contenedor
free -h
```

## Parte C — Crear los tópicos (replicable)

```bash
cd ~/gymflow/infra/kafka
chmod +x scripts/crear-topicos.sh      # solo la primera vez si git no conservó el permiso
./scripts/crear-topicos.sh             # crea/actualiza los 4 tópicos y muestra tópicos + consumer groups
./scripts/crear-topicos.sh describir   # solo muestra el estado (no cambia nada)
```

El script es **idempotente**: si un tópico existe le vuelve a aplicar sus configuraciones (`kafka-configs --alter`) y
aumenta particiones si tuviera menos. Se puede correr las veces que se quiera; así cualquiera reproduce la topología.
Usa las herramientas que trae el contenedor `kafka1` (`docker exec`), así que la EC2 no necesita instalar Kafka.

Salida esperada (resumen):

```
Topic: reservations.events  PartitionCount: 3  ReplicationFactor: 3  Configs: cleanup.policy=delete,min.insync.replicas=2,retention.ms=604800000
    Partition: 0  Leader: 1  Replicas: 1,2,3  Isr: 1,2,3
    ...
Topic: audit.timeline  PartitionCount: 3  ReplicationFactor: 3  Configs: cleanup.policy=compact,delete,min.compaction.lag.ms=3600000,...
```

Los líderes quedan repartidos entre los 3 brokers (uno por partición): la carga de escritura se reparte.

## Parte D — Probar con Kafka UI

Abre `http://<ip-elastica-ec2-kafka>:8080` e ingresa con `KAFKA_UI_USER` / `KAFKA_UI_PASSWORD`.

1. **Brokers**: 3 brokers en línea; el *Controller* es uno de ellos.
2. **Topics**: los 4 tópicos. En cada uno → **Overview**: 3 particiones, *Replication Factor* 3, *In Sync Replicas* 9 de 9.
   **Settings**: `cleanup.policy`, `retention.ms`, `min.insync.replicas` y (en `audit.timeline`) `min.compaction.lag.ms`.
3. **Producir un mensaje**: `reservations.events` → **Produce Message** → Key `42`, Value `{"prueba":true}` → Produce.
   En **Messages** aparece con su partición y offset. Repite con la misma clave: cae en **la misma partición** (eso es lo
   que garantiza el orden de los eventos de una reserva). Con otra clave puede caer en otra.
4. **Consumer groups**: aparecen `gymflow-report` y `gymflow-audit` cuando esos servicios se conectan (etapas siguientes),
   con sus miembros, partición asignada y **lag**.

> Los mensajes de prueba del punto 3 quedan en el tópico hasta que venza la retención. report los mandará al DLT por
> no ser un evento válido: sirve justamente para mostrar el manejo de errores.

### Desde la terminal (alternativa a la UI)

```bash
# Producir con clave (formato clave:valor), con acks=all como los microservicios
docker exec -it -e KAFKA_HEAP_OPTS=-Xmx128m kafka1 kafka-console-producer --bootstrap-server kafka1:29092 \
  --topic reservations.events --producer-property acks=all --property parse.key=true --property key.separator=:
# > 42:{"prueba":true}      (Ctrl+C para salir)

# Leer desde el principio, mostrando partición, offset y clave
docker exec -it -e KAFKA_HEAP_OPTS=-Xmx128m kafka1 kafka-console-consumer --bootstrap-server kafka1:29092 \
  --topic reservations.events --from-beginning --property print.partition=true --property print.offset=true --property print.key=true
```

### Tolerancia a fallas (`min.insync.replicas=2`)

```bash
docker stop kafka3
./scripts/crear-topicos.sh describir     # Isr: sin el 3; los líderes que tenía pasan a kafka1/kafka2
# producir con acks=all (comando de arriba): FUNCIONA, quedan 2 réplicas sincronizadas
docker stop kafka2
# producir de nuevo: ERROR NOT_ENOUGH_REPLICAS → Kafka rechaza en vez de aceptar algo que podría perderse
docker start kafka2 kafka3               # vuelven, se ponen al día y regresan al ISR
```

Probado en local: con `kafka3` detenido el mensaje se guarda; con `kafka2` y `kafka3` detenidos el productor recibe
`NotEnoughReplicasException` y el mensaje **no** queda en el tópico. Al volver, el ISR regresa a `1,2,3`.
Justo después del reinicio todos los líderes quedan en `kafka1`; Kafka los redistribuye solo a su líder preferido
(el primero de `Replicas`) en ~5 minutos (`auto.leader.rebalance.enable`, activo por defecto).

---

## Parte E — Conectar los microservicios de `ec2-apps`

En `ec2-apps` corren los 3 servicios nuevos (report, audit y kafka-admin) junto a los anteriores; reservations y
catalog ahora también publican en Kafka. En `infra/apps/.env` agrega (ver `.env.example`):

```
KAFKA_BOOTSTRAP_SERVERS=<ip-privada-ec2-kafka>:9092,<ip-privada-ec2-kafka>:9093,<ip-privada-ec2-kafka>:9094
REPORT_URL=http://ms-gymflow-report:8085
AUDIT_URL=http://ms-gymflow-audit:8086
KAFKA_ADMIN_URL=http://ms-gymflow-kafka-admin:8087
REPORT_TIME_ZONE=America/Santiago
```

Prueba de red desde `ec2-apps`, antes de levantar los servicios:

```bash
for p in 9092 9093 9094; do timeout 3 bash -c "</dev/tcp/<ip-privada-ec2-kafka>/$p" && echo "$p OK" || echo "$p CERRADO"; done
```

Si sale CERRADO: revisa la regla 9092-9094 de `gymflow-kafka-sg` (origen `gymflow-apps-sg`) y que ambas EC2 estén en la misma VPC.

Clonar los repos nuevos, compilar de a uno (memoria) y levantar:

```bash
cd ~/gymflow
for repo in ms-gymflow-report ms-gymflow-audit ms-gymflow-kafka-admin; do
  [ -d $repo ] || git clone https://github.com/Lajerarquia/$repo.git
done
for repo in infra ms-gymflow-bff ms-gymflow-catalog ms-gymflow-reservations; do git -C $repo pull; done
cd infra/apps
for s in catalog reservations bff report audit kafka-admin; do docker compose build ms-gymflow-$s; done
docker compose up -d
docker compose ps                     # los 8 en "healthy"
docker stats --no-stream              # memoria: ~3,4 GB de 4 GB en total
```

Comprobar que los consumidores se unieron a sus grupos:

```bash
docker compose logs ms-gymflow-report | grep -i "partitions assigned"
docker compose logs ms-gymflow-audit  | grep -i "partitions assigned"
```

Y en Kafka UI → Consumers: `gymflow-report` y `gymflow-audit` en estado STABLE, con 3 miembros cada uno
(`concurrency: 3`, un hilo por partición).

Demo de rebalanceo (indicador 8): `docker compose up -d --scale ms-gymflow-report=2` → en Kafka UI el grupo pasa a
6 miembros (3 tienen partición y 3 quedan en espera: no hay más particiones que repartir). Volver con
`--scale ms-gymflow-report=1` (cuidar la memoria).

## Probar en local (Docker Desktop)

```bash
cd infra/kafka
cp .env.example .env     # KAFKA_ADVERTISED_HOST=localhost, KAFKA_UI_PASSWORD=<cualquiera>
docker compose up -d
./scripts/crear-topicos.sh   # en Windows, desde Git Bash
```

Kafka UI en `http://localhost:8080`; los servicios usan `KAFKA_BOOTSTRAP_SERVERS=localhost:9092,localhost:9093,localhost:9094`.
Ojo: Kafka UI usa el **8080**, el mismo puerto del BFF local. Si corres los dos, levanta el BFF con `--server.port=18080` o
cambia el puerto publicado de la UI (`"18080:8080"`).

## Encender todo (después de cada Start Lab)

1. Start Lab → iniciar la RDS `gymflow-db` (esperar "Disponible").
2. `ec2-mq`: `cd ~/gymflow/infra/mq && docker compose up -d`
3. `ec2-kafka`: `cd ~/gymflow/infra/kafka && docker compose up -d` → esperar `healthy` (`docker compose ps`).
   Los tópicos y offsets se conservan en los volúmenes; no hay que volver a correr el script.
4. `ec2-apps`: `cd ~/gymflow/infra/apps && docker compose up -d`

Con `restart: unless-stopped` y Docker habilitado al inicio, los contenedores vuelven solos al encender la EC2.

## Actualizar después de un push

```bash
cd ~/gymflow/infra && git pull
cd kafka && docker compose up -d       # recrea solo lo que cambió
./scripts/crear-topicos.sh             # si cambió la topología
```

## Trampas

- **`KAFKA_ADVERTISED_HOST` equivocado** (la IP elástica, o `localhost` en AWS): el cliente se conecta al primer broker
  pero luego falla con `Connection to node 1 (...) could not be established`. Debe ser la IP privada de `ec2-kafka`.
- **Cambiar `KAFKA_ADVERTISED_HOST`** exige recrear los brokers: `docker compose up -d --force-recreate kafka1 kafka2 kafka3`.
- **ZooKeeper sin quórum** (un solo nodo arriba): los brokers no arrancan. `docker compose ps` muestra cuál está unhealthy.
- **`InconsistentClusterIdException`** al arrancar un broker: se borraron los volúmenes de ZooKeeper pero no los de Kafka
  (o al revés). Solución en un entorno de prueba: `docker compose down -v` y volver a crear los tópicos.
- **Memoria**: `docker stats`. Si un broker se reinicia con `OOMKilled` (`docker inspect kafka1 --format '{{.State.OOMKilled}}'`),
  subir su `mem_limit` y bajar el de Kafka UI.
- **No se pueden reducir particiones** ni cambiar el factor de replicación con `kafka-topics --alter`: la topología se
  define bien desde el principio (el script solo aumenta).
- **Kafka 4.x / cp 8.x** no tienen ZooKeeper: no subir las imágenes a esas versiones sin migrar a KRaft.
