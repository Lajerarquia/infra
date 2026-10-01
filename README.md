# infra — despliegue de GymFlow en AWS

Infraestructura del proyecto GymFlow (DSY1107, EP1): Docker Compose para la EC2 y la guía del API Gateway.

```
infra/
├── apps/
│   ├── compose.yml      # BFF + catalog + reservations, construidos desde los repos clonados al lado
│   └── .env.example     # variables (sin contraseñas); se copia como .env en la EC2
└── docs/
    └── api-gateway.md   # HTTP API con JWT Authorizer de Azure AD → BFF en la EC2
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
└──────────────────────────────────────────────────────────────────────────────────────────┘
          catalog y reservations ──> Amazon RDS PostgreSQL 17 (gymflow-db, sin acceso público)
```

| Recurso | Valor |
|---|---|
| EC2 | `ec2-apps`, t3.medium (4 GB), Amazon Linux 2023, IP elástica `44.217.171.96` |
| Security group EC2 | `gymflow-apps-sg`: entrada 22 (SSH) y 8080 (BFF) |
| RDS | `gymflow-db`, PostgreSQL 17, db.t3.micro, us-east-1a, base `gymflow`, usuario `postgres`, puerto 5432 |
| Acceso a RDS | Solo desde la EC2, mediante el security group `rds-ec2-1` |

### Decisiones del `compose.yml`

- **Solo el BFF publica un puerto (8080).** catalog y reservations solo tienen `expose`: se ven dentro de la red
  `gymflow` por su nombre (`http://ms-gymflow-catalog:8082`), pero no desde internet. Así se cumple el flujo
  JWT → API Gateway → BFF → microservicio.
- **Healthchecks sobre `/actuator/health`.** En catalog y reservations ese health incluye la conexión a RDS:
  "healthy" significa que la app arrancó **y** llega a la base. Se hace con `bash` y `/dev/tcp` porque la imagen
  `eclipse-temurin:17-jre` no garantiza tener `curl`.
- **`depends_on` con `service_healthy`.** Primero catalog; luego reservations (lo necesita para los cupos);
  al final el BFF, que solo arranca cuando los dos están sanos.
- **512 MB por contenedor** (`mem_limit`). Java 17 detecta el límite del contenedor; con
  `-XX:MaxRAMPercentage=70` el heap llega a unos 360 MB y queda margen para metaspace e hilos.
  `-XX:+ExitOnOutOfMemoryError` hace que, si se agota la memoria, el proceso termine y Docker lo reinicie
  (`restart: unless-stopped`) en vez de quedar colgado. Total: 1,5 GB de 4 GB.
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

### 3. Clonar los 4 repos en `~/gymflow`

```bash
mkdir -p ~/gymflow && cd ~/gymflow
for repo in infra ms-gymflow-bff ms-gymflow-catalog ms-gymflow-reservations; do
  git clone https://github.com/Lajerarquia/$repo.git
done
ls ~/gymflow                   # infra  ms-gymflow-bff  ms-gymflow-catalog  ms-gymflow-reservations
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
- Lo demás (Azure, URLs internas, CORS) ya viene con los valores correctos.

### 5. Construir y levantar

```bash
cd ~/gymflow/infra/apps
docker compose build           # la primera vez tarda varios minutos (descarga dependencias de Maven)
docker compose up -d
docker compose ps              # esperar a que los 3 digan "healthy" (hasta ~2 minutos)
```

Si la compilación se queda sin memoria (las tres en paralelo), constrúyelas de a una:

```bash
docker compose build ms-gymflow-catalog
docker compose build ms-gymflow-reservations
docker compose build ms-gymflow-bff
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
for repo in infra ms-gymflow-bff ms-gymflow-catalog ms-gymflow-reservations; do git -C $repo pull; done
cd infra/apps && docker compose up -d --build
```

### Detener

```bash
cd ~/gymflow/infra/apps && docker compose down
```

## API Gateway

Ver [docs/api-gateway.md](docs/api-gateway.md).
