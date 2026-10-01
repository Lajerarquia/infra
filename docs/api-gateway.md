# API Gateway (HTTP API) para GymFlow

El front Angular llama al API Gateway con `Authorization: Bearer <access token de Azure AD>`. El Gateway valida
el JWT con un **JWT Authorizer** y, si es válido, reenvía la petición al BFF en la EC2. El BFF vuelve a validar
el token completo (firma, issuer, audience, vigencia, `tid`), aplica la autorización por rol y llama a los
microservicios de dominio.

```
Navegador ──HTTPS──> https://<API_ID>.execute-api.us-east-1.amazonaws.com/api/...
                        │ 1. Preflight OPTIONS (CORS): lo responde el Gateway, sin autorizador
                        │ 2. JWT Authorizer: issuer v2 del tenant + audience + scope access_as_user
                        ▼
                     http://44.217.171.96:8080/api/{proxy}  (ms-gymflow-bff en la EC2)
```

## Valores

| Dato | Valor |
|---|---|
| Región | `us-east-1` (la misma de la EC2 y de RDS) |
| Tipo | HTTP API (no REST API) |
| Issuer | `https://login.microsoftonline.com/6a3e6e0e-c7e4-4a0a-9a66-1778df0b3b19/v2.0` |
| Audiences | `ee1bba85-7f98-4977-bf8b-f6acebb7ec6f` (tokens v2) y `api://ee1bba85-7f98-4977-bf8b-f6acebb7ec6f` (tokens v1) |
| Identity source | `$request.header.Authorization` |
| Scope requerido | `access_as_user` |
| Ruta | `ANY /api/{proxy+}` |
| Integración | HTTP URI, método `ANY`, `http://44.217.171.96:8080/api/{proxy}` |
| CORS | Origen `http://localhost:4200` |

**Por qué dos audiences:** el manifiesto usa `requestedAccessTokenVersion: 2`, así que `aud` es el GUID del client id.
Si por alguna razón llega un token v1, `aud` es `api://<CLIENT_ID>`. El BFF acepta ambos y el Gateway debe hacer
lo mismo, o rechazaría tokens que el BFF sí aceptaría.

## Pasos en la consola de AWS

Consola → **API Gateway** → región **us-east-1**.

### 1. Crear el HTTP API

1. **Create API** → **HTTP API** → **Build**.
2. **Integrations** → **Add integration** → **HTTP**:
   - Method: `ANY`
   - URL endpoint: `http://44.217.171.96:8080/api/{proxy}`
3. API name: `gymflow-api` → **Next**.
4. **Configure routes**: método `ANY`, resource path `/api/{proxy+}`, integration target: la integración anterior → **Next**.
5. **Stages**: deja `$default` con **Auto-deploy** activado → **Next** → **Create**.

`{proxy+}` captura todo lo que viene después de `/api/` (ej. `reservations/15/status`) y la integración lo
vuelve a poner en `{proxy}`. Así `GET /api/reservations/15` llega al BFF como `GET /api/reservations/15`.
El query string (`?status=CONFIRMADA`) y la cabecera `Authorization` se reenvían tal cual.

### 2. Crear el JWT Authorizer

1. Menú izquierdo → **Authorization** → pestaña **Manage authorizers** → **Create**.
2. Authorizer type: **JWT**.
   - Name: `azure-ad-jwt`
   - Identity source: `$request.header.Authorization`
   - Issuer URL: `https://login.microsoftonline.com/6a3e6e0e-c7e4-4a0a-9a66-1778df0b3b19/v2.0`
   - Audience: agrega las dos:
     - `ee1bba85-7f98-4977-bf8b-f6acebb7ec6f`
     - `api://ee1bba85-7f98-4977-bf8b-f6acebb7ec6f`
3. **Create**.

El Gateway descarga las llaves públicas desde `<issuer>/.well-known/openid-configuration`. Con ellas verifica la
firma, `exp`/`nbf`, el `iss` (debe coincidir exacto, incluido `/v2.0`) y que `aud` sea una de las dos audiences.

### 3. Asociar el authorizer a la ruta

1. **Authorization** → pestaña **Attach authorizers to routes** → selecciona `ANY /api/{proxy+}`.
2. Elige `azure-ad-jwt` → **Attach authorizer**.
3. En **Authorization scopes** agrega `access_as_user` → **Save**.

Con el scope, el Gateway exige además que el claim `scp` del token contenga `access_as_user`. Si falta, responde
403 antes de llegar al BFF. Es la misma regla que aplica el BFF (toda ruta exige el scope).

### 4. Configurar CORS

1. Menú izquierdo → **CORS** → **Configure**.
   - Access-Control-Allow-Origin: `http://localhost:4200`
   - Access-Control-Allow-Methods: `GET`, `POST`, `PUT`, `DELETE`, `OPTIONS`
   - Access-Control-Allow-Headers: `authorization`, `content-type`
   - Access-Control-Max-Age: `3600`
   - Access-Control-Allow-Credentials: **No** (el token va en una cabecera, no en cookies)
2. **Save**.

### 5. El preflight OPTIONS va sin autorizador

Antes de un `GET` o `POST` con cabecera `Authorization`, el navegador envía un **preflight** `OPTIONS`, **sin** el token.
Si ese `OPTIONS` cayera en la ruta `ANY /api/{proxy+}`, el JWT Authorizer lo rechazaría con 401 y el navegador
bloquearía la llamada real con un error de CORS.

Con CORS configurado en el paso 4, **API Gateway responde el preflight por su cuenta**, sin pasar por el
autorizador y sin llegar al BFF, aunque la ruta sea `ANY`. Por eso:

- **No** crees una ruta `OPTIONS` con autorizador.
- **No** hace falta una ruta `OPTIONS` aparte. Solo si algún día se quitara la configuración CORS del Gateway,
  habría que crear `OPTIONS /api/{proxy+}` **sin autorizador** y dejar que el BFF responda el preflight.
- Con CORS en el Gateway, las cabeceras CORS que mande el BFF se ignoran. Las del Gateway son las que valen.

### 6. Anotar la URL

En **Stages** → `$default` aparece la **Invoke URL**: `https://<API_ID>.execute-api.us-east-1.amazonaws.com`.
Esa es la base del front (`apiBaseUrl` en `frontend-gymflow/src/environments/environment.ts`, que hoy tiene el
placeholder `https://<API_ID>.execute-api.<REGION>.amazonaws.com`).

## Lo mismo con AWS CLI (CloudShell)

Equivale a los pasos anteriores, por si prefieres crearlo desde CloudShell (que ya tiene las credenciales del Learner Lab).

```bash
REGION=us-east-1
TENANT=6a3e6e0e-c7e4-4a0a-9a66-1778df0b3b19
CLIENT=ee1bba85-7f98-4977-bf8b-f6acebb7ec6f

API_ID=$(aws apigatewayv2 create-api --region $REGION --name gymflow-api --protocol-type HTTP \
  --cors-configuration '{"AllowOrigins":["http://localhost:4200"],"AllowMethods":["GET","POST","PUT","DELETE","OPTIONS"],"AllowHeaders":["authorization","content-type"],"MaxAge":3600}' \
  --query ApiId --output text)

AUTH_ID=$(aws apigatewayv2 create-authorizer --region $REGION --api-id $API_ID --name azure-ad-jwt \
  --authorizer-type JWT --identity-source '$request.header.Authorization' \
  --jwt-configuration "{\"Issuer\":\"https://login.microsoftonline.com/$TENANT/v2.0\",\"Audience\":[\"$CLIENT\",\"api://$CLIENT\"]}" \
  --query AuthorizerId --output text)

INT_ID=$(aws apigatewayv2 create-integration --region $REGION --api-id $API_ID \
  --integration-type HTTP_PROXY --integration-method ANY \
  --integration-uri 'http://44.217.171.96:8080/api/{proxy}' --payload-format-version 1.0 \
  --query IntegrationId --output text)

aws apigatewayv2 create-route --region $REGION --api-id $API_ID --route-key 'ANY /api/{proxy+}' \
  --target integrations/$INT_ID --authorization-type JWT --authorizer-id $AUTH_ID \
  --authorization-scopes access_as_user

aws apigatewayv2 create-stage --region $REGION --api-id $API_ID --stage-name '$default' --auto-deploy

echo "https://$API_ID.execute-api.$REGION.amazonaws.com"
```

## Probar

```bash
API=https://<API_ID>.execute-api.us-east-1.amazonaws.com
```

1. **Preflight** (sin token). Debe responder `204` con `access-control-allow-origin: http://localhost:4200`:
   ```bash
   curl -i -X OPTIONS "$API/api/me" \
     -H "Origin: http://localhost:4200" \
     -H "Access-Control-Request-Method: GET" \
     -H "Access-Control-Request-Headers: authorization"
   ```
2. **Sin token**: `401 {"message":"Unauthorized"}`. Lo responde el **Gateway**: la petición no llega al BFF.
   ```bash
   curl -i "$API/api/me"
   ```
3. **Con token válido**: `200` con el JSON del BFF (`/api/me` devuelve oid, nombre, roles, scopes).
   Copia el access token desde el navegador después de iniciar sesión (DevTools → Network → una llamada a la API →
   cabecera `Authorization`):
   ```bash
   TOKEN='eyJ0eXAiOiJKV1Qi...'
   curl -i "$API/api/me" -H "Authorization: Bearer $TOKEN"
   ```
4. **Rol sin permiso** (ej. un Socio en `POST /api/catalog/services`): `403` en JSON. Este lo responde el
   **BFF**, porque el Gateway solo valida el token y el scope, no los roles.

| Respuesta | Quién la da | Motivo |
|---|---|---|
| 401 `{"message":"Unauthorized"}` | API Gateway | Sin token, firma inválida, expirado, issuer o audience incorrectos |
| 403 `{"message":"Forbidden"}` | API Gateway | Token válido sin el scope `access_as_user` |
| 401/403 `{"timestamp","status","error","message","path"}` | BFF | Revalidación del JWT o rol sin permiso |
| 503 `{"message":"Service Unavailable"}` | API Gateway | El BFF no responde (EC2 apagada o contenedor caído) |

## Notas

- **El puerto 8080 de la EC2 está abierto a internet** porque el Gateway llega por la IP pública y no tiene IPs fijas.
  No es un hueco: el BFF valida el JWT completo por su cuenta, así que llamarlo directo sin un token válido
  también da 401.
- **El tramo Gateway → EC2 va por HTTP, sin cifrar.** Para la EP1 es aceptable. La mejora sería HTTPS en la EC2
  o una VPC Link con un balanceador interno.
- **Learner Lab:** al terminar la sesión la EC2 se detiene. La IP elástica se mantiene, así que la integración
  sigue apuntando bien. Los contenedores vuelven solos al encender (`restart: unless-stopped` y Docker habilitado
  con `systemctl enable docker`).
- El timeout máximo de una integración de HTTP API es de 30 s.
