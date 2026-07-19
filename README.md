# Crona

Sistema para **programar mensajes de WhatsApp** (texto, fotos, videos y PDF) que se envían automáticamente en una fecha y hora futuras, hacia contactos o grupos, usando tu instalación existente de **Evolution API v2** en tu VPS.

- **Crona Server** (Node 20 + Fastify + Prisma + PostgreSQL): única fuente de verdad. Guarda los mensajes, ejecuta el scheduler, recibe webhooks de Evolution y notifica por ntfy. Los mensajes se envían aunque ninguna app esté abierta.
- **Crona para iOS y macOS** (SwiftUI multiplataforma): clientes delgados. Mac ↔ iPhone se sincronizan solos porque ambos hablan con el mismo servidor (REST + WebSocket).
- **Evolution API v2**: ya instalada en tu VPS; no se modifica.

Ver [SPEC.md](SPEC.md) para la especificación completa y [DECISIONS.md](DECISIONS.md) para las decisiones de implementación y la evidencia de cada fase.

---

## 1. Puesta en marcha en el VPS

### 1.1 Base de datos

Crea la base `crona` en el Postgres existente de Evolution:

```bash
docker exec -it <contenedor_postgres> psql -U <usuario> -c "CREATE DATABASE crona;"
```

### 1.2 Red de Docker

El nombre de la red del compose de Evolution varía. Verifícalo y ponlo en `docker-compose.yml` → `networks.evolution-net.name`:

```bash
docker network ls
```

### 1.3 Secretos y configuración

```bash
cp .env.example .env
openssl rand -hex 32   # → JWT_SECRET
openssl rand -hex 32   # → ENCRYPTION_KEY
openssl rand -hex 24   # → WEBHOOK_SECRET
```

Edita `.env`:

| Variable | Valor |
|---|---|
| `DATABASE_URL` | `postgresql://user:pass@<servicio_postgres>:5432/crona` |
| `PUBLIC_URL` | `https://crona.TUDOMINIO.com` (Opción A) o `http://IP_DEL_VPS:3000` (Opción B) |
| `INTERNAL_URL` | `http://crona:3000` (no cambiar: red interna de Docker) |

### 1.4 Levantar

```bash
docker compose up -d --build && docker compose logs -f crona
```

Las migraciones corren solas en el arranque del contenedor.

**Opción A — con dominio y TLS (recomendada)**: incluye el servicio `caddy` del compose y edita `Caddyfile` con tu dominio. TLS automático.

**Opción B — solo HTTP (sin dominio)**: elimina el servicio `caddy` y descomenta `ports: ["3000:3000"]` en `crona`. Las apps se conectan a `http://IP_DEL_VPS:3000`.

> ⚠️ Con HTTP los JWT y el contenido viajan en claro por internet. Aceptable para arrancar; tres upgrades posibles:
> 1. **Caddy + dominio** — TLS automático, 3 líneas (Opción A).
> 2. **Cloudflare Tunnel** apuntando a `crona:3000` — sin abrir puertos.
> 3. **Tailscale** — VPS + dispositivos en un tailnet, conectarse por la IP privada.

### 1.5 Registrar al admin y configurar Evolution

```bash
URL=https://crona.TUDOMINIO.com   # o http://IP:3000

# Primer usuario registrado = ADMIN (sin invitación)
curl -s -X POST $URL/auth/register -H "Content-Type: application/json" \
  -d '{"email":"tu@correo.com","password":"…","name":"Sebastián"}'
# guarda el accessToken de la respuesta en $TOKEN

# Configurar Evolution y probar
curl -s -X PUT $URL/admin/settings -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"evolutionBaseUrl":"http://evolution-api:8080","evolutionGlobalApiKey":"LA_KEY_GLOBAL","ntfyBaseUrl":"https://ntfy.sh"}'
curl -s -X POST $URL/admin/settings/test -H "Authorization: Bearer $TOKEN"
# → {"ok":true,"version":"2.x.x"}
```

`evolutionBaseUrl` es la URL **interna** de Evolution (ej. `http://evolution-api:8080` si comparten red Docker). `evolutionGlobalApiKey` es el `AUTHENTICATION_API_KEY` del `.env` de Evolution. Todo esto también se puede hacer desde la app (Ajustes → Servidor Evolution, solo rol ADMIN).

---

## 2. Apps iOS y macOS

Requisitos: Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd apps/Crona && xcodegen generate && open Crona.xcodeproj
```

En Xcode:

1. Signing & Capabilities → Team = tu **Personal Team** (cuenta gratuita).
2. Run en **My Mac**, luego en el iPhone conectado.
3. En el iPhone: Ajustes → General → VPN y gestión de dispositivos → confiar en tu Apple ID.

> ⚠️ El perfil gratuito **expira a los 7 días**: repite Run desde Xcode. Los envíos **no** se detienen mientras tanto (los hace el servidor).
>
> ⚠️ No agregues capabilities/entitlements (Push, iCloud, App Groups): el build falla al firmar con Personal Team. Las notificaciones del iPhone llegan por **ntfy**, no por APNs.

Primera vez en la app: ingresa la URL de tu servidor Crona (acepta `http://` con advertencia) → crea tu cuenta o inicia sesión → vincula tu número escaneando el QR.

---

## 3. Notificaciones push (ntfy)

1. Instala **ntfy** desde el App Store en el iPhone.
2. En Crona → Ajustes → Notificaciones: genera tu topic (ej. `crona-seb-a8k2x1`) y guárdalo.
3. En la app ntfy: suscríbete a ese topic.

Recibirás push cuando un mensaje **falle** (3 intentos) o tu WhatsApp **se desconecte**; activa "Notificar también envíos exitosos" si quieres confirmación de cada envío. El topic funciona como secreto — no lo compartas.

**ntfy self-hosted**: su `server.yml` necesita `upstream-base-url: "https://ntfy.sh"` para que el push llegue a iOS vía APNs. Configura la URL de tu ntfy en Ajustes → Servidor Evolution (campo ntfy) y tu token en Ajustes → Notificaciones si usa auth.

En macOS las notificaciones son locales (mientras la app corre), sin ntfy.

---

## 4. Invitar a más usuarios

El registro está cerrado por invitación: en la app (rol ADMIN) → Ajustes → Usuarios e invitaciones → **Crear código de invitación** (expira en 7 días). Cada usuario vincula **sus propias** instancias de WhatsApp y solo ve sus mensajes.

---

## 5. Desarrollo local

```bash
# Postgres de desarrollo
docker run -d --name catchapp-dev-pg -e POSTGRES_USER=catchapp -e POSTGRES_PASSWORD=catchapp \
  -e POSTGRES_DB=catchapp -p 5433:5432 postgres:16-alpine

cd server
cp ../.env.example .env    # ajusta DATABASE_URL a localhost:5433 y genera secretos
npx prisma migrate dev
npm run dev                # API + worker en :3000
```

| Comando | Qué hace |
|---|---|
| `cd server && npm run dev` | Backend en modo watch |
| `cd server && npx prisma migrate dev --name <nombre>` | Nueva migración |
| `cd server && npm run build` | Compilar TypeScript |
| `cd apps/Crona && xcodegen generate` | Regenerar proyecto Xcode |

---

## 6. Notas de operación

- **Zona horaria**: todo se guarda en UTC; cada mensaje conserva su `timezone` para calcular recurrencias en hora local.
- **Reintentos**: fallo 1 → +2 min, fallo 2 → +10 min, fallo 3 → notificación ntfy y estado FAILED (o salta a la siguiente ocurrencia si es recurrente).
- **Idempotencia**: claim con `FOR UPDATE SKIP LOCKED`; tras un crash a mitad de envío el log queda `FAILED / INTERRUMPIDO` para revisión manual — nunca se duplica un mensaje.
- **"Leído"** depende de la privacidad del destinatario; en **grupos** espera ver hasta "entregado".
- **Anti-ban**: delay de 1.8 s por mensaje + jitter entre mensajes del mismo tick. Crona es para uso personal; no programes ráfagas masivas (Baileys es no-oficial y WhatsApp puede banear).
- Los webhooks crudos (`WebhookEventRaw`, para depurar el mapeo) se limpian automáticamente a los 7 días.
