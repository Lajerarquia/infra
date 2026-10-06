# RabbitMQ de GymFlow en AWS (EP2)

Clúster de 2 nodos RabbitMQ 3.13 con Management UI en una EC2 propia (`ec2-mq`), según el caso (secciones 7 y 8).
`ms-gymflow-reservations` publica; `ms-gymflow-notify` consume; `ms-gymflow-mq-admin` administra. Los tres corren en
`ec2-apps`.

```
ec2-apps (gymflow-apps-sg)                              ec2-mq (gymflow-mq-sg)
  reservations ──AMQP 5672/5673──────────────────────>   rabbit1 :5672  ┐ clúster (red Docker "gymflow-mq",
  notify       <─AMQP 5672/5673──────────────────────    rabbit2 :5673  ┘  puertos 4369/25672 internos)
  mq-admin     ──AMQP + HTTP 15672───────────────────>   Management UI :15672 (rabbit1)
tu PC ──HTTP 15672 (solo tu IP)──────────────────────>   Management UI
```

## Topología (la declara ms-gymflow-notify al conectarse)

| Exchange | Tipo | Bindings |
|---|---|---|
| `cmd.direct` | direct | `email.send` → `q.cmd.email` · `checkin.ticket` → `q.cmd.checkin` · `invoice.gen` → `q.cmd.invoice` |
| `cmd.topic` | topic | `email.*` → `q.cmd.email` · `checkin.#` → `q.cmd.checkin` · `invoice.*` → `q.cmd.invoice` |
| `cmd.dead.dlx` | direct | `email` → `q.cmd.email.dlq` · `checkin` → `q.cmd.checkin.dlq` · `invoice` → `q.cmd.invoice.dlq` |

Al confirmar una reserva, reservations publica `EMAIL_RESERVA_CONFIRMADA` por `cmd.direct` (`email.send`) y
`CHECKIN_TICKET_CREADO` por `cmd.topic` (`checkin.ticket.created`).

## 1. Crear la EC2 `ec2-mq` (consola de EC2, Learner Lab)

- Nombre `ec2-mq`, **Amazon Linux 2023**, **t3.medium** (4 GB: los 2 nodos usan 1 GB cada uno).
- Par de llaves: el mismo del Learner Lab (`vockey` / `labsuser.pem`).
- **Misma VPC que `ec2-apps`** (la por defecto), para que se hablen por IP privada.
- Security group nuevo `gymflow-mq-sg` (ver paso 2).
- Opcional: asociar una IP elástica para que la URL de la Management UI no cambie entre sesiones.

Anota la **IP privada** de `ec2-mq` (pestaña Networking). No cambia al detener e iniciar la instancia; la pública sí
(salvo con IP elástica).

## 2. Security group `gymflow-mq-sg`

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| TCP personalizado | 5672-5673 | security group `gymflow-apps-sg` | AMQP de reservations, notify y mq-admin |
| TCP personalizado | 15672 | security group `gymflow-apps-sg` | API de Management para mq-admin |
| TCP personalizado | 15672 | Mi IP | Management UI desde tu navegador |
| SSH | 22 | Mi IP | administrar la EC2 |

Usar el **security group como origen** (no una IP): cualquier instancia con `gymflow-apps-sg` puede conectarse y nada
más. 4369 y 25672 (puertos internos del clúster) **no** se abren: los dos nodos están en la misma red Docker.

## 3. Preparar `ec2-mq`

```bash
ssh -i labsuser.pem ec2-user@<ip-publica-ec2-mq>

sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
# Docker Compose v2 (Amazon Linux 2023 no lo trae en dnf)
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
exit                                   # volver a entrar para que tome el grupo docker
```

## 4. Levantar el clúster

```bash
ssh -i labsuser.pem ec2-user@<ip-publica-ec2-mq>
mkdir -p ~/gymflow && cd ~/gymflow && git clone https://github.com/Lajerarquia/infra.git
cd ~/gymflow/infra/mq
cp .env.example .env && chmod 600 .env
openssl rand -hex 24                   # copia el resultado como RABBITMQ_ERLANG_COOKIE
nano .env                              # RABBITMQ_DEFAULT_PASS y RABBITMQ_ERLANG_COOKIE
docker compose up -d
docker compose ps                      # rabbit1 y rabbit2 "healthy" (~30 s)
docker exec rabbit1 rabbitmq-diagnostics -q cluster_status   # Running Nodes: rabbit@rabbit1 y rabbit@rabbit2
docker stats --no-stream               # cada nodo bajo 1 GiB
```

Management UI: `http://<ip-publica-ec2-mq>:15672` con `gymflow` y la contraseña del `.env`. En **Overview → Nodes**
deben aparecer los 2 nodos. Las colas aparecen cuando arranca notify (paso 5).

> El log muestra `Overriding Erlang cookie using the value set in the environment`: es solo una advertencia de que
> la variable está deprecada; el clúster se forma igual (comprobado con 3.13.7).

## 5. Conectar `ec2-apps`

```bash
ssh -i labsuser.pem ec2-user@44.217.171.96
cd ~/gymflow
git -C infra pull && git -C ms-gymflow-reservations pull
git clone https://github.com/Lajerarquia/ms-gymflow-notify.git
git clone https://github.com/Lajerarquia/ms-gymflow-mq-admin.git
cd infra/apps && nano .env
#   RABBITMQ_ADDRESSES=<ip-privada-ec2-mq>:5672,<ip-privada-ec2-mq>:5673
#   RABBITMQ_USERNAME=gymflow
#   RABBITMQ_PASSWORD=<la misma de infra/mq/.env>
#   RABBITMQ_MANAGEMENT_URL=http://<ip-privada-ec2-mq>:15672
#   SIMULAR_FALLA=NINGUNA
# De a una para no quedarse sin memoria compilando:
docker compose build ms-gymflow-reservations
docker compose build ms-gymflow-notify
docker compose build ms-gymflow-mq-admin
docker compose up -d
docker compose ps                      # los 5 "healthy"
```

La columna `miembro_email` de la tabla `reserva` la agrega Hibernate (`JPA_DDL_AUTO=update`) al arrancar.

## 6. Probar

**Flujo completo.** En la URL pública, un socio reserva una clase y un instructor la confirma. Luego, en `ec2-apps`:

```bash
docker logs ms-gymflow-reservations | grep Publicado     # 2 mensajes: cmd.direct y cmd.topic
docker logs ms-gymflow-notify | grep -E "\[EMAIL\]|\[TICKET\]|ACK"
```

El `[EMAIL]` muestra como destinatario el email del socio. Los dos `ACK` comparten `traceId` y `correlationId`.

**mq-admin** (desde tu PC, con un túnel SSH):

```bash
ssh -i labsuser.pem -L 8084:localhost:8084 ec2-user@44.217.171.96
# en otra terminal:
curl -s localhost:8084/api/mq/queues
curl -s -X POST localhost:8084/api/mq/test-messages -H "Content-Type: application/json" \
  -d '{"exchange":"cmd.direct","routingKey":"invoice.gen","type":"INVOICE_GENERAR","payload":{"plan":"PLUS"}}'
docker logs ms-gymflow-notify | grep INVOICE              # en ec2-apps
```

**Reintentos y DLQ** (en `ec2-apps`):

```bash
cd ~/gymflow/infra/apps
SIMULAR_FALLA=TRANSITORIA docker compose up -d ms-gymflow-notify
# confirmar otra reserva en la web
docker logs ms-gymflow-notify | grep -E "Reintento|NACK"   # Reintento 1, Reintento 2, NACK → DLQ
curl -s localhost:8084/api/mq/queues                        # (túnel) q.cmd.email.dlq y q.cmd.checkin.dlq con 1
SIMULAR_FALLA=NINGUNA docker compose up -d ms-gymflow-notify
curl -s -X POST localhost:8084/api/mq/queues/q.cmd.email.dlq/reprocess   # vuelve a q.cmd.email y se procesa
```

**Idempotencia**: publicar dos veces el mismo `eventId` con mq-admin; notify lo procesa una vez y registra
"Duplicado ignorado".

**Aislamiento de red** (desde tu PC, deben fallar):

```powershell
Test-NetConnection <ip-publica-ec2-mq> -Port 5672     # TcpTestSucceeded: False (solo ec2-apps)
Test-NetConnection 44.217.171.96 -Port 8084           # False (mq-admin solo en 127.0.0.1)
```

**Nodo caído**: `docker stop rabbit2` en `ec2-mq`. Las apps siguen conectadas a rabbit1. Ojo: las colas son clásicas
y viven en el nodo donde se crearon (se ve en la columna `node`). Si se detiene ese nodo, sus colas no están
disponibles hasta que vuelva. Con 2 nodos no hay quórum (se necesitan 3 para tolerar una caída), por eso no se usan
colas quorum. El clúster de 2 nodos demuestra el clúster, no alta disponibilidad.

## Encender todo (después de cada Start Lab)

1. Start Lab.
2. Iniciar la RDS `gymflow-db` y esperar "Disponible".
3. Iniciar `ec2-mq` y luego `ec2-apps`.
4. En `ec2-mq`: `cd ~/gymflow/infra/mq && docker compose up -d` (con `restart: unless-stopped` suelen volver solos).
5. En `ec2-apps`: `cd ~/gymflow/infra/apps && docker compose up -d`.
6. Abrir la URL pública.

## Trampas

- `guest` no sirve desde otra máquina (RabbitMQ solo lo acepta desde localhost). Se usa el usuario `gymflow`.
- Si `RABBITMQ_ADDRESSES` apunta a la IP **pública** de `ec2-mq`, el security group la bloquea (el origen permitido
  es `gymflow-apps-sg`, que solo calza por la red privada). Usar la IP privada.
- Si se cambia el Erlang cookie después de crear los volúmenes, los nodos no se reconocen: `docker compose down -v`
  (borra los mensajes) y volver a levantar.
- La API de Management actualiza los contadores cada ~5 s: `GET /api/mq/queues` puede tardar en reflejar un cambio.
