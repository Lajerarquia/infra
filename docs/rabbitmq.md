# RabbitMQ de GymFlow en AWS (EP2)

**Todo se despliega en EC2.** Las pruebas locales (Docker Desktop, `./mvnw test`) solo sirven para validar antes del push.

| EC2 | Qué corre | Compose |
|---|---|---|
| `ec2-apps` (ya existe, IP elástica `44.217.171.96`) | bff, catalog, reservations, **notify**, **mq-admin** (sin puertos publicados; mq-admin vía BFF) | `infra/apps/compose.yml` |
| `ec2-mq` (nueva) | RabbitMQ 3.13 con Management UI, clúster de 2 nodos (`rabbit1`, `rabbit2`) | `infra/mq/compose.yml` |

```
ec2-apps (gymflow-apps-sg)                              ec2-mq (gymflow-mq-sg)
  reservations ──AMQP 5672/5673──────────────────────>   rabbit1 :5672  ┐ clúster (red Docker "gymflow-mq",
  notify       <─AMQP 5672/5673──────────────────────    rabbit2 :5673  ┘  puertos 4369/25672 internos)
  mq-admin     ──AMQP + HTTP 15672───────────────────>   Management UI :15672 (rabbit1)
tu PC ──HTTP 15672 (solo tu IP)───────────────────────>   ec2-mq
consola AWS ──EC2 Instance Connect (SSH 22)──────────>   ec2-mq y ec2-apps
```

`ms-gymflow-reservations` publica, `ms-gymflow-notify` consume y `ms-gymflow-mq-admin` administra. Entre las dos EC2 el
tráfico va por **IP privada** (misma VPC); la IP elástica de `ec2-mq` es para la Management UI. A las dos EC2 se entra con **EC2 Instance Connect** desde la consola.

## Topología (la declara ms-gymflow-notify al conectarse)

| Exchange | Tipo | Bindings |
|---|---|---|
| `cmd.direct` | direct | `email.send` → `q.cmd.email` · `checkin.ticket` → `q.cmd.checkin` · `invoice.gen` → `q.cmd.invoice` |
| `cmd.topic` | topic | `email.*` → `q.cmd.email` · `checkin.#` → `q.cmd.checkin` · `invoice.*` → `q.cmd.invoice` |
| `cmd.dead.dlx` | direct | `email` → `q.cmd.email.dlq` · `checkin` → `q.cmd.checkin.dlq` · `invoice` → `q.cmd.invoice.dlq` |

Al confirmar una reserva, reservations publica `EMAIL_RESERVA_CONFIRMADA` por `cmd.direct` (`email.send`) y
`CHECKIN_TICKET_CREADO` por `cmd.topic` (`checkin.ticket.created`).

---

## Parte A — Crear `ec2-mq` en el Learner Lab

Antes: **Start Lab**, esperar el círculo verde y abrir la consola de AWS (región **us-east-1**).

### A1. Security group `gymflow-mq-sg`

EC2 → **Security Groups** → **Create security group**:

- Name: `gymflow-mq-sg` · Description: `RabbitMQ de GymFlow` · VPC: la **misma VPC de `ec2-apps`** (la por defecto;
  compruébalo en la pestaña Networking de `ec2-apps`).
- **Inbound rules** (Add rule por cada fila):

| Type | Port range | Source | Para qué |
|---|---|---|---|
| Custom TCP | `5672-5673` | Custom → `gymflow-apps-sg` (escribe el nombre y elige el `sg-...`) | AMQP de reservations, notify y mq-admin |
| Custom TCP | `15672` | Custom → `gymflow-apps-sg` | API de Management para mq-admin |
| Custom TCP | `15672` | My IP | Management UI desde tu navegador |
| SSH | `22` | Anywhere-IPv4 (`0.0.0.0/0`) | EC2 Instance Connect (ver nota) |

- Outbound: dejar la regla por defecto (todo el tráfico). **Create security group**.

Usar el security group como origen (y no una IP) permite exactamente a las instancias con `gymflow-apps-sg`, y solo por la
red privada. No se abren 4369 ni 25672: los dos nodos están en la misma red Docker de `ec2-mq`.

> **SSH 22 abierto a `0.0.0.0/0`:** EC2 Instance Connect no se conecta desde tu PC sino desde las IP del servicio de AWS,
> así que con "My IP" la conexión falla. La autenticación sigue siendo por llave: Instance Connect envía una llave
> temporal (60 s) solo para el usuario que abre la sesión desde la consola, y no hay contraseñas.
>
> "My IP" (regla de 15672) es la IP pública de tu red en ese momento. Si cambias de red (casa / Duoc), edita esa regla.

### A2. Lanzar la instancia

EC2 → **Instances** → **Launch instances**:

| Campo | Valor |
|---|---|
| Name | `ec2-mq` |
| AMI | **Amazon Linux 2023** (64-bit x86) |
| Instance type | **t3.medium** (4 GB; los 2 nodos usan 1 GB cada uno) |
| Key pair | `vockey` (la misma de `ec2-apps`; EC2 Instance Connect no la necesita, pero el Lab la pide) |
| Network settings → Edit | VPC: la misma de `ec2-apps` · Auto-assign public IP: Enable · **Select existing security group: `gymflow-mq-sg`** |
| Storage | 8 GiB gp3 (por defecto) alcanza: imagen de RabbitMQ + mensajes; `rabbitmq.conf` frena a 1 GB libre |

**Launch instance** y esperar a que el estado sea **Running** y los checks **2/2**.

Anota la **IP privada** de `ec2-mq` (Instances → `ec2-mq` → Details → *Private IPv4 address*). No cambia al detener e
iniciar la instancia; es la que usan las apps.

### A3. IP elástica

EC2 → **Elastic IPs** → **Allocate Elastic IP address** → Allocate. Luego, con la nueva IP seleccionada:
**Actions → Associate Elastic IP address** → Resource type: Instance → Instance: `ec2-mq` → **Associate**.

Anota la IP elástica: la usarás para `http://<ip-elastica-ec2-mq>:15672`. No cambia entre sesiones del Lab.

### A4. Preparar `ec2-mq` (Docker, Compose y git)

**Conectarse con EC2 Instance Connect:** EC2 → Instances → `ec2-mq` → **Connect** → pestaña **EC2 Instance Connect** → usuario `ec2-user` → **Connect** (se abre una terminal en el navegador). Amazon Linux 2023 trae Instance Connect instalado.

```bash
sudo dnf install -y docker git
sudo systemctl enable --now docker          # Docker arranca solo cada vez que el Lab enciende la EC2
sudo usermod -aG docker ec2-user
# Docker Compose v2 (Amazon Linux 2023 no lo trae en dnf)
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
exit                                        # cierra la sesión para que tome el grupo docker
```

Vuelve a **conectarte con EC2 Instance Connect** a `ec2-mq` y comprueba:

```bash
docker --version && docker compose version  # ambos responden
```

---

## Parte B — Desplegar RabbitMQ en `ec2-mq`

**Conectarse con EC2 Instance Connect:** EC2 → Instances → `ec2-mq` → **Connect** → pestaña **EC2 Instance Connect** → usuario `ec2-user` → **Connect** (se abre una terminal en el navegador).

```bash
mkdir -p ~/gymflow && cd ~/gymflow
git clone https://github.com/Lajerarquia/infra.git     # si es privado: usuario + personal access token
cd ~/gymflow/infra/mq
cp .env.example .env && chmod 600 .env
openssl rand -hex 24                                    # copia el resultado para RABBITMQ_ERLANG_COOKIE
nano .env
#   RABBITMQ_DEFAULT_USER=gymflow
#   RABBITMQ_DEFAULT_PASS=<contraseña nueva; la misma irá en infra/apps/.env>
#   RABBITMQ_ERLANG_COOKIE=<lo que dio openssl>
docker compose up -d
docker compose ps                                       # rabbit1 y rabbit2 "healthy" (~30 s)
```

Verificar:

```bash
docker exec rabbit1 rabbitmq-diagnostics -q cluster_status   # Running Nodes: rabbit@rabbit1 y rabbit@rabbit2
docker stats --no-stream                                     # cada nodo bajo 1 GiB (unos 200 MB en reposo)
free -h                                                      # memoria libre de la t3.medium
```

Management UI: `http://<ip-elastica-ec2-mq>:15672`, usuario `gymflow` y la contraseña del `.env`. En **Overview → Nodes**
aparecen los 2 nodos. Las colas aparecen cuando arranca notify (Parte C).

> El log muestra `Overriding Erlang cookie using the value set in the environment`: es solo una advertencia de que esa
> variable está deprecada; el clúster se forma igual (comprobado con 3.13.7).

---

## Parte C — Desplegar notify y mq-admin en `ec2-apps`

notify y mq-admin corren en `ec2-apps` junto a bff, catalog y reservations, con el mismo `infra/apps/compose.yml`.

### C1. Traer el código (primera vez)

**Conectarse con EC2 Instance Connect:** EC2 → Instances → `ec2-apps` → **Connect** → pestaña **EC2 Instance Connect** → usuario `ec2-user` → **Connect**.

```bash
cd ~/gymflow
git -C infra pull
git -C ms-gymflow-reservations pull
git -C ms-gymflow-bff pull                    # rutas /api/admin/mq/**
git clone https://github.com/Lajerarquia/ms-gymflow-notify.git
git clone https://github.com/Lajerarquia/ms-gymflow-mq-admin.git
ls ~/gymflow   # infra  ms-gymflow-bff  ms-gymflow-catalog  ms-gymflow-mq-admin  ms-gymflow-notify  ms-gymflow-reservations
```

### C2. Variables de RabbitMQ en `infra/apps/.env`

```bash
cd ~/gymflow/infra/apps
nano .env      # agregar al final (el resto del .env no cambia):
#   RABBITMQ_ADDRESSES=<ip-privada-ec2-mq>:5672,<ip-privada-ec2-mq>:5673
#   RABBITMQ_USERNAME=gymflow
#   RABBITMQ_PASSWORD=<la misma de infra/mq/.env en ec2-mq>
#   RABBITMQ_MANAGEMENT_URL=http://<ip-privada-ec2-mq>:15672
#   SIMULAR_FALLA=NINGUNA
#   MQ_ADMIN_URL=http://ms-gymflow-mq-admin:8084
```

Usar la **IP privada** de `ec2-mq`, no la elástica: el security group solo acepta a `gymflow-apps-sg` por la red privada.

Antes de construir, comprobar que `ec2-apps` llega a RabbitMQ:

```bash
timeout 3 bash -c 'exec 3<>/dev/tcp/<ip-privada-ec2-mq>/5672' && echo "5672 OK"
timeout 3 bash -c 'exec 3<>/dev/tcp/<ip-privada-ec2-mq>/5673' && echo "5673 OK"
curl -s -u gymflow:<contraseña> http://<ip-privada-ec2-mq>:15672/api/overview | head -c 80; echo
```

### C3. Construir (de a una: la t3.medium se queda sin memoria si compila todo a la vez)

```bash
cd ~/gymflow/infra/apps
docker compose build ms-gymflow-reservations
docker compose build ms-gymflow-bff
docker compose build ms-gymflow-notify
docker compose build ms-gymflow-mq-admin
docker compose up -d
docker compose ps              # los 5 "healthy" (hasta ~2 minutos)
docker stats --no-stream       # bff/catalog/reservations bajo 512 MiB; notify y mq-admin bajo 384 MiB
```

Al arrancar, reservations agrega la columna `miembro_email` a la tabla `reserva` (`JPA_DDL_AUTO=update`) y notify crea en
RabbitMQ los exchanges, las 6 colas y los bindings (se ven en la Management UI, pestaña **Queues and Streams**, con
1 consumidor en cada cola principal).

---

## Parte D — Probar en AWS

**Flujo completo.** En `https://0z97ecbdsc.execute-api.us-east-1.amazonaws.com`, `socio@` reserva una clase e
`instructor@` la confirma. En `ec2-apps`:

```bash
docker logs ms-gymflow-reservations | grep Publicado     # 2 mensajes: cmd.direct y cmd.topic
docker logs ms-gymflow-notify | grep -E "\[EMAIL\]|\[TICKET\]|ACK"
```

El `[EMAIL]` muestra como destinatario el email del socio. Los dos `ACK` comparten `traceId` y `correlationId`.

**Pantalla RabbitMQ (mq-admin a través del BFF, sin abrir puertos).** Inicia sesión con tu usuario **Admin** y abre
**RabbitMQ** en el menú (`/admin/mq`; los demás roles no ven el enlace y el BFF les responde 403). El camino es
frontend → API Gateway (JWT Authorizer) → BFF `/api/admin/mq/**` → mq-admin por la red interna → RabbitMQ.

- **Colas principales y DLQ**: mensajes listos, no confirmados y consumidores (cada cola principal debe tener 1).
- **Publicar mensaje de prueba**: elige exchange, routing key (cada opción dice a qué cola llega) y tipo.
  - `cmd.direct` + `invoice.gen` + `INVOICE_GENERAR` → en `ec2-apps`: `docker logs ms-gymflow-notify | grep INVOICE`.
  - `cmd.topic` + `email.reminder` → llega a `q.cmd.email` por `email.*` (comodín de topic).
  - `cmd.direct` + `email.reminder` → error **422**: direct no usa comodines, ninguna cola lo recibe.
  - Tipo `MENSAJE_PRUEBA` → notify no lo conoce: NACK y aparece en `q.cmd.email.dlq`.
  - **Idempotencia**: después de publicar, marca "Repetir el último eventId" y publica otra vez; notify registra
    `Duplicado ignorado` (`docker logs ms-gymflow-notify | grep Duplicado`).
- **Reprocesar** (en cada DLQ con mensajes): los devuelve a su cola principal.
- Los contadores vienen de la API de Management y se actualizan cada ~5 s (la pantalla recarga sola tras cada acción).

**Reintentos y DLQ.** En `ec2-apps` (conectarse con EC2 Instance Connect):

```bash
cd ~/gymflow/infra/apps
SIMULAR_FALLA=TRANSITORIA docker compose up -d ms-gymflow-notify
# confirmar otra reserva en la web
docker logs ms-gymflow-notify | grep -E "Reintento|NACK"   # Reintento 1, Reintento 2, NACK → DLQ
SIMULAR_FALLA=NINGUNA docker compose up -d ms-gymflow-notify
```

En la pantalla RabbitMQ, `q.cmd.email.dlq` y `q.cmd.checkin.dlq` muestran 1 mensaje cada una; **Reprocesar** los
devuelve y esta vez notify los procesa (ACK).

**Sin la pantalla (opcional, PowerShell).** Con el token de Admin (F12 → Network → cualquier petición a `/api/...` →
copiar el valor de `Authorization`):

```powershell
$G = "https://0z97ecbdsc.execute-api.us-east-1.amazonaws.com"
$H = @{ Authorization = "Bearer eyJ..." }          # el valor copiado (dura ~1 hora)
Invoke-RestMethod "$G/api/admin/mq/queues" -Headers $H | Format-Table
Invoke-RestMethod "$G/api/admin/mq/test-messages" -Method Post -Headers $H -ContentType "application/json" `
  -Body '{"exchange":"cmd.direct","routingKey":"invoice.gen","type":"INVOICE_GENERAR","payload":{"plan":"PLUS"}}'
Invoke-RestMethod "$G/api/admin/mq/queues/q.cmd.email.dlq/reprocess" -Method Post -Headers $H
```

Con el token de `instructor@` responde **403**, y sin token **401** (lo responde el JWT Authorizer del Gateway).

**Aislamiento de red** (desde tu PC; las tres deben fallar):

```powershell
Test-NetConnection <ip-elastica-ec2-mq> -Port 5672    # TcpTestSucceeded: False (AMQP solo desde ec2-apps)
Test-NetConnection 44.217.171.96 -Port 8084           # False (mq-admin sin puertos publicados)
Test-NetConnection 44.217.171.96 -Port 8083           # False (notify no publica puertos)
```

**Nodo caído**: `docker stop rabbit2` en `ec2-mq` (conectarse con EC2 Instance Connect). Las apps siguen conectadas a rabbit1. Las colas son clásicas y viven
en el nodo donde se crearon (columna "Nodo" de la pantalla RabbitMQ): si se detiene ese nodo, sus colas no están
disponibles hasta que vuelva. Con 2 nodos no hay quórum (se necesitan 3 para tolerar una caída), por eso no se usan
colas quorum: el clúster de 2 nodos demuestra el clúster, no alta disponibilidad. `docker start rabbit2` para volver.

---

## Actualizar después de un push

```bash
# ec2-apps
cd ~/gymflow
for repo in infra ms-gymflow-bff ms-gymflow-catalog ms-gymflow-reservations ms-gymflow-notify ms-gymflow-mq-admin; do
  git -C $repo pull
done
cd infra/apps
docker compose build <servicio-que-cambió>     # de a uno
docker compose up -d

# ec2-mq (solo si cambió infra/mq)
cd ~/gymflow/infra && git pull && cd mq && docker compose up -d
```

## Encender todo (después de cada Start Lab)

1. Start Lab.
2. Iniciar la RDS `gymflow-db` y esperar "Disponible".
3. Iniciar `ec2-mq`; conectarse con EC2 Instance Connect y: `cd ~/gymflow/infra/mq && docker compose up -d` (con `restart: unless-stopped` y Docker
   habilitado suelen volver solos; el comando no hace daño si ya están arriba).
4. Iniciar `ec2-apps`; conectarse con EC2 Instance Connect y: `cd ~/gymflow/infra/apps && docker compose up -d`.
5. Abrir la URL pública.

Al terminar, **detener las dos EC2** (y la RDS) para no gastar el crédito del Lab: son dos t3.medium.

## Trampas

- `guest` no sirve desde otra máquina (RabbitMQ solo lo acepta desde localhost). Se usa el usuario `gymflow`.
- `RABBITMQ_ADDRESSES` con la IP **elástica** de `ec2-mq` no conecta: el security group permite `gymflow-apps-sg`, que solo
  calza por la red privada. Usar la IP privada.
- Si la VPC de `ec2-mq` no es la de `ec2-apps`, no se ven por IP privada y la regla con `gymflow-apps-sg` no aplica.
- Si se cambia el Erlang cookie después de crear los volúmenes, los nodos no se reconocen: `docker compose down -v`
  (borra los mensajes) y volver a levantar.
- La API de Management actualiza los contadores cada ~5 s: `GET /api/mq/queues` puede tardar en reflejar un cambio.
- Compilar varias imágenes a la vez en `ec2-apps` puede dejarla sin memoria: `docker compose build` de a un servicio.
