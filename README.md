# infra — despliegue de GymFlow en AWS

Infraestructura del proyecto GymFlow (DSY1107): Docker Compose para las EC2 y la guía del API Gateway.
EP2: RabbitMQ en una EC2 propia (`ec2-mq`) y dos servicios nuevos en `ec2-apps` (notify y mq-admin).
EP5: Kafka (3 ZooKeeper + 3 brokers + Kafka UI) en una EC2 propia (`ec2-kafka`) para eventos de analítica y auditoría.

```
infra/
├── apps/                # EC2 ec2-apps
│   ├── compose.yml      # bff + catalog + reservations + notify + mq-admin, construidos desde los repos clonados al lado
│   └── .env.example     # variables (sin contraseñas); se copia como .env en la EC2
├── mq/                  # EC2 ec2-mq (EP2)
│   ├── compose.yml      # RabbitMQ 3.13 con Management UI, clúster de 2 nodos
│   ├── rabbitmq.conf    # formación del clúster y límites de memoria/disco
│   └── .env.example     # usuario, contraseña y Erlang cookie
├── kafka/               # EC2 ec2-kafka (EP5)
│   ├── compose.yml      # 3 ZooKeeper + 3 brokers Confluent 7.9 + Kafka UI
│   ├── .env.example     # IP anunciada por los brokers y login de Kafka UI
│   └── scripts/
│       └── crear-topicos.sh  # crea/actualiza los 4 tópicos (idempotente) y describe tópicos y consumer groups
└── docs/
    ├── api-gateway.md   # HTTP API con JWT Authorizer de Azure AD → BFF en la EC2
    ├── rabbitmq.md      # ec2-mq, security groups, despliegue y pruebas de RabbitMQ
    └── kafka.md         # ec2-kafka, security group, tópicos, Kafka UI y pruebas de tolerancia a fallas
```

## Arquitectura

```
Angular + MSAL ──Bearer JWT──> API Gateway (HTTP API, JWT Authorizer)
                                   │  http://44.217.171.96:8080/api/{proxy}
                                   ▼
EC2 ec2-apps (t3.medium, Amazon Linux 2023) ── red Docker "gymflow" ─────────────────────────┐
│  ms-gymflow-bff :8080  (único puerto publicado)                                            │
│     ├─> ms-gymflow-reservations :8081 ──> ms-gymflow-catalog (tomar/devolver cupo)          │
│     └─> ms-gymflow-catalog :8082                                                            │
│  ms-gymflow-notify :8083 (consumidor)     ms-gymflow-mq-admin :8084 (vía BFF /api/admin/mq) │
│  EP5: ms-gymflow-report :8085 (vía BFF /api/report)   ms-gymflow-audit :8086 (/api/audit)    │
│       ms-gymflow-kafka-admin :8087 (vía BFF /api/admin/kafka)                               │
└──────────────────────────────────────────────────────────────────────────────────────────┘
          catalog, reservations, report y audit ──> Amazon RDS PostgreSQL 17 (gymflow-db, sin acceso público)
          reservations ──publica──> EC2 ec2-mq: RabbitMQ rabbit1 :5672 + rabbit2 :5673 (UI :15672)
                                         └──> notify consume (ACK/NACK, reintentos, DLQ)
          reservations, catalog ──publican──> EC2 ec2-kafka: kafka1..3 :9092-9094 (Kafka UI :8080)
                                         ├──> report consume reservations.events (grupo gymflow-report)
                                         └──> audit consume audit.timeline (grupo gymflow-audit)
```

| Recurso | Valor |
|---|---|
| EC2 | `ec2-apps`, t3.medium (4 GB), Amazon Linux 2023, IP elástica `44.217.171.96` |
| Security group EC2 | `gymflow-apps-sg`: entrada 22 (SSH) y 8080 (BFF) |
| RDS | `gymflow-db`, PostgreSQL 17, db.t3.micro, us-east-1a, base `gymflow`, usuario `postgres`, puerto 5432 |
| Acceso a RDS | Solo desde la EC2, mediante el security group `rds-ec2-1` |
| EC2 RabbitMQ (EP2) | `ec2-mq`, t3.medium (4 GB), Amazon Linux 2023, IP elástica; 2 nodos de 1 GB cada uno |
| Security group RabbitMQ | `gymflow-mq-sg`: 5672-5673 y 15672 desde `gymflow-apps-sg`; 15672 desde tu IP; 22 desde `0.0.0.0/0` (EC2 Instance Connect) |
| EC2 Kafka (EP5) | `ec2-kafka`, t3.medium (4 GB), Amazon Linux 2023, IP elástica, 16 GiB; 3 ZooKeeper + 3 brokers + Kafka UI |
| Security group Kafka | `gymflow-kafka-sg`: 9092-9094 desde `gymflow-apps-sg`; 8080 (Kafka UI) desde tu IP; 22 desde `0.0.0.0/0` |

### Decisiones del `compose.yml`

- **Solo el BFF publica un puerto (8080).** catalog y reservations solo tienen `expose`: se ven dentro de la red
  `gymflow` por su nombre (`http://ms-gymflow-catalog:8082`), pero no desde internet. Así se cumple el flujo
  JWT → API Gateway → BFF → microservicio. notify y mq-admin tampoco publican puertos; mq-admin se usa a través
  del BFF (`/api/admin/mq/**`, solo rol Admin).
- **Healthchecks sobre `/actuator/health`.** En catalog y reservations ese health incluye la conexión a RDS:
  "healthy" significa que la app arrancó **y** llega a la base. Se hace con `bash` y `/dev/tcp` porque la imagen
  `eclipse-temurin:17-jre` no garantiza tener `curl`. En reservations **no** se incluye RabbitMQ (si el broker cae,
  las reservas siguen y el BFF puede arrancar); en notify y mq-admin sí.
- **`depends_on` con `service_healthy`.** Primero catalog; luego reservations (lo necesita para los cupos);
  al final el BFF, que solo arranca cuando los dos están sanos.
- **512 MB por contenedor** (`mem_limit`) para bff, catalog y reservations, **384 MB** para notify, mq-admin, report
  y audit, y **320 MB** para kafka-admin (sin BD, solo `AdminClient`). Java 17 detecta el límite del contenedor; con
  `-XX:MaxRAMPercentage=70` el heap llega a unos 360 MB (270 MB en los de 384) y queda margen para metaspace e hilos.
  `-XX:+ExitOnOutOfMemoryError` hace que, si se agota la memoria, el proceso termine y Docker lo reinicie
  (`restart: unless-stopped`) en vez de quedar colgado. Total: ~3,4 GB de 4 GB. **Cuidar la memoria**: es una
  t3.medium del Learner Lab y compilar con Maven también consume; por eso las imágenes se construyen de a una.
- **EP5: report y audit sin `container_name`**, para poder escalarlos (`docker compose up -d --scale
  ms-gymflow-report=2`) y mostrar el rebalanceo de su consumer group. Una segunda instancia suma 384 MB: en
  `ec2-apps` queda muy justo, así que la demo se hace un momento y se vuelve a `--scale ms-gymflow-report=1`.
- **EP5: ningún health depende de Kafka.** Si `ec2-kafka` está apagada, reservations y catalog siguen respondiendo
  (los eventos perdidos quedan en el log) y el BFF arranca igual.
- **Variables obligatorias con `${VAR:?mensaje}`.** Si falta algo en el `.env`, `docker compose` se detiene
  con ese mensaje en vez de arrancar mal configurado.
- **Dockerfiles** (en cada repo de servicio): compilan en dos etapas con el wrapper de Maven sobre
  `eclipse-temurin:17-jdk`. La imagen final solo tiene el JRE 17 y el jar, y corre con un usuario sin privilegios.

## Despliegue en la EC2

Todos los comandos van en la EC2, con el usuario `ec2-user`.

### 1. Conectarse

Desde tu PC, con la llave del Learner Lab (`labsuser.pem`, descargada desde "AWS Details"):

```bash
ssh -i labsuser.pem ec2-user@44.217.171.96
```

### 2. Verificar Docker, Compose y git

```bash
docker --version
docker compose version
docker ps                      # si dice "permission denied", ver abajo
sudo systemctl enable --now docker   # Docker arranca solo cuando el Learner Lab vuelve a encender la EC2
sudo dnf install -y git        # Amazon Linux 2023 no trae git por defecto
```

Si `docker ps` responde "permission denied":

```bash
sudo usermod -aG docker ec2-user
exit                           # salir y volver a entrar por ssh para que tome el grupo
```

### 3. Clonar los 9 repos en `~/gymflow`

```bash
mkdir -p ~/gymflow && cd ~/gymflow
for repo in infra ms-gymflow-bff ms-gymflow-catalog ms-gymflow-reservations ms-gymflow-notify ms-gymflow-mq-admin \
            ms-gymflow-report ms-gymflow-audit ms-gymflow-kafka-admin; do
  [ -d $repo ] || git clone https://github.com/Lajerarquia/$repo.git
done
ls ~/gymflow
```

Si los repos son privados, git pide usuario y un *personal access token* de GitHub (no la contraseña).

### 4. Crear el `.env`

```bash
cd ~/gymflow/infra/apps
cp .env.example .env
chmod 600 .env                 # solo ec2-user puede leerlo
nano .env                      # o: vi .env
```

Completa:

- `DB_URL`: reemplaza `<endpoint-rds>` por el endpoint de `gymflow-db` (consola de RDS → Connectivity & security).
  Ejemplo: `jdbc:postgresql://gymflow-db.xxxxxxxx.us-east-1.rds.amazonaws.com:5432/gymflow?sslmode=require`
- `DB_PASSWORD`: la contraseña real de `postgres`. **Solo aquí**, nunca en un repo.
- `RABBITMQ_ADDRESSES`, `RABBITMQ_MANAGEMENT_URL` y `RABBITMQ_PASSWORD` (EP2): IP privada de `ec2-mq` y la contraseña de
  `infra/mq/.env`. Ver [docs/rabbitmq.md](docs/rabbitmq.md).
- `KAFKA_BOOTSTRAP_SERVERS` (EP5): IP privada de `ec2-kafka` con los puertos 9092, 9093 y 9094. Ver
  [docs/kafka.md](docs/kafka.md), Parte E.
- Lo demás (Azure, URLs internas, CORS) ya viene con los valores correctos.

### 5. Construir y levantar

```bash
cd ~/gymflow/infra/apps
docker compose build           # la primera vez tarda varios minutos (descarga dependencias de Maven)
docker compose up -d
docker compose ps              # esperar a que los 8 digan "healthy" (hasta ~2 minutos)
```

Si la compilación se queda sin memoria (varias en paralelo), constrúyelas de a una:

```bash
for s in catalog reservations bff notify mq-admin report audit kafka-admin; do
  docker compose build ms-gymflow-$s
done
docker compose up -d
```

### 6. Probar

En la EC2:

```bash
curl -s http://localhost:8080/actuator/health      # {"status":"UP"}
curl -s -i http://localhost:8080/api/me            # 401 en JSON: falta el token (el BFF valida el JWT)
```

Desde tu PC (pasa por el security group, puerto 8080):

```bash
curl -s http://44.217.171.96:8080/actuator/health          # {"status":"UP"}
curl -s -m 5 http://44.217.171.96:8082/actuator/health     # debe fallar: catalog no está publicado
```

### Revisar logs y estado

```bash
docker compose logs -f ms-gymflow-bff
docker compose logs ms-gymflow-catalog | grep -iE "hikari|error"   # conexión a RDS
docker stats --no-stream                                            # memoria de cada contenedor (límite 512 MiB)
```

Si catalog o reservations quedan en "unhealthy", casi siempre es la base de datos. Revisa que el endpoint de
`DB_URL` sea correcto, que la contraseña esté bien y que la EC2 tenga asociado el security group `rds-ec2-1`.

Para ver las tablas que creó Hibernate, sin instalar nada en la EC2:

```bash
docker run --rm -it postgres:17 psql "host=<endpoint-rds> dbname=gymflow user=postgres sslmode=require" -c '\dt'
```

### Actualizar después de un push

```bash
cd ~/gymflow
for repo in infra ms-gymflow-bff ms-gymflow-catalog ms-gymflow-reservations ms-gymflow-notify ms-gymflow-mq-admin \
            ms-gymflow-report ms-gymflow-audit ms-gymflow-kafka-admin; do git -C $repo pull; done
cd infra/apps && docker compose up -d --build
```

### Detener

```bash
cd ~/gymflow/infra/apps && docker compose down
```

## API Gateway

Ver [docs/api-gateway.md](docs/api-gateway.md).

## RabbitMQ (EP2)

Ver [docs/rabbitmq.md](docs/rabbitmq.md): crear `ec2-mq`, security groups, levantar el clúster y probar el flujo.

## Kafka (EP5)

Ver [docs/kafka.md](docs/kafka.md): crear `ec2-kafka`, security group, levantar el clúster, crear los tópicos con
`kafka/scripts/crear-topicos.sh` y probar con Kafka UI. Orden de encendido: RDS → `ec2-mq` → **`ec2-kafka`** → `ec2-apps`.
