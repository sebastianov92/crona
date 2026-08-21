# Crona — Especificación técnica completa

> **Documento para Claude Code.** Lee este documento completo antes de escribir código.
> Todas las decisiones de producto y arquitectura ya están tomadas — no preguntes por alternativas de stack, implementa lo especificado. Si encuentras una ambigüedad técnica real, resuélvela con la opción más simple y documéntala en `DECISIONS.md`.

---

## 1. Qué es Crona

Crona es un sistema para **programar mensajes de WhatsApp** (texto, fotos y videos) que se envían automáticamente en una fecha y hora futuras, hacia **contactos individuales o grupos**, usando una instalación existente de **Evolution API v2** en un VPS del usuario.

Componentes:

1. **Crona Server** — backend en el VPS (junto a Evolution API, mismo Docker network). Es la **única fuente de verdad**: guarda los mensajes programados, ejecuta el scheduler que los envía, recibe webhooks de Evolution y notifica por ntfy. Los mensajes se envían aunque ninguna app esté abierta.
2. **Crona para iOS y macOS** — una sola app SwiftUI multiplataforma, clientes delgados del backend. La sincronización Mac ↔ iPhone es automática porque ambos leen/escriben contra el mismo servidor (REST + WebSocket).
3. **Evolution API v2** — ya instalada y corriendo en el VPS del usuario. NO se modifica; solo se consume su API REST y sus webhooks.

```
┌─────────────┐   ┌─────────────┐
│  Crona   │   │  Crona   │
│    macOS    │   │     iOS     │
└──────┬──────┘   └──────┬──────┘
       │  HTTPS (REST + WS)  │
       └─────────┬──────────┘
                 ▼
   ┌──────────────────────────┐        ┌──────────────┐
   │   Crona Server (VPS)  │──POST─▶│  ntfy server │──▶ 📱 push
   │  API · Worker · Webhooks │        └──────────────┘
   └──────┬──────────▲────────┘
          │ REST     │ webhooks (red interna Docker)
          ▼          │
   ┌──────────────────────────┐
   │    Evolution API v2      │──▶ WhatsApp
   │   (ya instalada, VPS)    │
   └──────────────────────────┘
          │
          ▼
   ┌──────────────┐
   │  PostgreSQL  │  (el mismo de Evolution; base de datos separada `crona`)
   └──────────────┘
```

---

## 2. Decisiones ya tomadas (no re-discutir)

| Tema | Decisión |
|---|---|
| Apps cliente | **SwiftUI nativo multiplataforma** (un solo codebase), iOS 17+ / macOS 14+ |
| Proyecto Xcode | Generado con **XcodeGen** (`project.yml`) para que Claude Code pueda crear/modificar el proyecto como texto |
| Backend | **Node.js 20 + TypeScript + Fastify + Prisma + PostgreSQL** |
| Scheduler | Worker de **polling cada 30 s** contra Postgres con `FOR UPDATE SKIP LOCKED`. **Sin Redis, sin cron por mensaje** |
| Base de datos | Reutilizar el PostgreSQL de Evolution creando una **base separada `crona`**. Fallback: contenedor propio si no fuera accesible |
| Usuarios | **Multiusuario con login completo** (email + contraseña, JWT). Primer usuario registrado = ADMIN. Registro posterior solo con **código de invitación** |
| Instancias | Cada usuario crea y vincula **sus propias instancias** de Evolution (QR). UI enfocada a una instancia activa; schema soporta varias |
| Extras v1 | ✅ Mensajes **recurrentes** (diario/semanal/mensual) · ✅ Notificaciones de envío/fallo vía **ntfy** · ✅ **Historial** con estados entregado/leído |
| Notificaciones iPhone | **ntfy** (self-hosted friendly). ⚠️ La app iOS se instala por **sideload con cuenta gratuita**: **PROHIBIDO** incluir la capability Push Notifications / entitlement `aps-environment` — el build fallaría al firmar con Personal Team |
| Evolution API | **v2.x** — usar los formatos de body de v2 (planos), NO los de v1 (`textMessage`/`mediaMessage` anidados) |
| HTTP sin TLS | **Soportado como caso normal**: tanto Evolution como el propio Crona Server pueden servirse por `http://` (escenario típico de self-hosting). Las apps incluyen la excepción ATS (9.1) y derivan `ws://`/`wss://` del esquema. HTTPS recomendado, no obligatorio |
| Zona horaria | Todo en **UTC** en DB (`timestamptz`); cada mensaje guarda su `timezone` (default `America/Guayaquil`, sin DST) |
| Idioma UI | Español |

---

## 3. Estructura del repositorio (monorepo)

```
crona/
├── SPEC.md                    # este documento
├── DECISIONS.md               # decisiones tomadas durante implementación
├── docker-compose.yml         # crona-server (+ caddy opcional)
├── .env.example
├── server/
│   ├── package.json
│   ├── tsconfig.json
│   ├── prisma/schema.prisma
│   └── src/
│       ├── index.ts           # bootstrap Fastify + worker
│       ├── config.ts          # env vars validadas con zod
│       ├── plugins/           # auth (JWT), errores, cors-off
│       ├── routes/            # auth, users, admin, instances, recipients, media, messages, webhooks, ws
│       ├── services/
│       │   ├── evolution.ts   # cliente HTTP de Evolution API v2
│       │   ├── scheduler.ts   # worker de envío
│       │   ├── recurrence.ts  # cálculo de próxima ocurrencia (usar luxon)
│       │   ├── ntfy.ts
│       │   ├── media.ts       # storage disco + URLs internas firmadas
│       │   └── crypto.ts      # AES-256-GCM para keys de Evolution
│       └── ws/hub.ts          # broadcast por usuario
└── apps/
    └── Crona/
        ├── project.yml        # XcodeGen: target multiplataforma iOS+macOS
        └── Sources/           # (ver sección 9)
```

---

## 4. Modelo de datos (Prisma — `server/prisma/schema.prisma`)

```prisma
generator client { provider = "prisma-client-js" }
datasource db { provider = "postgresql"; url = env("DATABASE_URL") }

enum Role            { ADMIN USER }
enum InstanceStatus  { CREATED CONNECTING CONNECTED DISCONNECTED }
enum RecipientKind   { CONTACT GROUP }
enum MessageType     { TEXT IMAGE VIDEO DOCUMENT }
enum Recurrence      { NONE DAILY WEEKLY MONTHLY }
enum ScheduleStatus  { ACTIVE PAUSED COMPLETED CANCELLED FAILED }
enum LogStatus       { SENDING SENT DELIVERED READ FAILED }

model User {
  id            String   @id @default(uuid())
  email         String   @unique
  passwordHash  String                     // argon2id
  name          String
  role          Role     @default(USER)
  ntfyTopic     String?                    // topic personal, ej. "crona-sebastian-x7k2"
  ntfyToken     String?                    // opcional si el server ntfy usa auth
  notifyOnSent  Boolean  @default(false)   // notificar también envíos exitosos
  createdAt     DateTime @default(now())
  instances     Instance[]
  messages      ScheduledMessage[]
  media         Media[]
  refreshTokens RefreshToken[]
}

model Invite {
  id          String    @id @default(uuid())
  code        String    @unique            // 8 chars aleatorios
  createdById String
  usedById    String?
  expiresAt   DateTime
  createdAt   DateTime  @default(now())
}

model RefreshToken {
  id        String    @id @default(uuid())
  userId    String
  user      User      @relation(fields: [userId], references: [id], onDelete: Cascade)
  tokenHash String    @unique              // sha256 del token
  expiresAt DateTime
  revokedAt DateTime?
}

// Singleton (id = 1). Config global editable solo por ADMIN desde la app.
model ServerSettings {
  id                       Int      @id @default(1)
  evolutionBaseUrl         String                    // ej. http://evolution-api:8080 (red interna)
  evolutionGlobalApiKeyEnc String                    // cifrada AES-256-GCM
  ntfyBaseUrl              String   @default("https://ntfy.sh")
  updatedAt                DateTime @updatedAt
}

model Instance {
  id              String         @id @default(uuid())
  userId          String
  user            User           @relation(fields: [userId], references: [id], onDelete: Cascade)
  name            String                          // nombre visible: "Personal", "Negocio"
  instanceName    String         @unique          // nombre en Evolution: "u{shortid}-personal"
  tokenEnc        String                          // apikey/hash de la instancia, cifrada
  phoneNumber     String?                         // se llena al conectar
  profilePicUrl   String?
  status          InstanceStatus @default(CREATED)
  lastConnectedAt DateTime?
  createdAt       DateTime       @default(now())
  recipients      Recipient[]
  messages        ScheduledMessage[]
}

// Cache local de contactos y grupos de WhatsApp (se sincroniza bajo demanda)
model Recipient {
  id          String        @id @default(uuid())
  instanceId  String
  instance    Instance      @relation(fields: [instanceId], references: [id], onDelete: Cascade)
  jid         String                        // "5939XXXXXXXX@s.whatsapp.net" | "1203...@g.us"
  displayName String
  pictureUrl  String?
  kind        RecipientKind
  phoneNumber String?                       // solo contactos
  syncedAt    DateTime      @default(now())
  @@unique([instanceId, jid])
  @@index([instanceId, kind])
}

model Media {
  id          String   @id @default(uuid())
  userId      String
  user        User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  fileName    String
  mimeType    String
  sizeBytes   Int
  storagePath String                        // relativo a MEDIA_DIR
  createdAt   DateTime @default(now())
}

model ScheduledMessage {
  id                  String         @id @default(uuid())
  userId              String
  user                User           @relation(fields: [userId], references: [id])
  instanceId          String
  instance            Instance       @relation(fields: [instanceId], references: [id])
  // snapshot del destinatario (por si luego cambia el cache)
  recipientJid        String
  recipientName       String
  recipientKind       RecipientKind
  recipientPictureUrl String?
  // contenido
  type                MessageType
  body                String?                     // texto del mensaje o caption del media
  mediaId             String?
  // programación
  timezone            String         @default("America/Guayaquil")
  scheduledAt         DateTime                    // primera ejecución (UTC)
  recurrence          Recurrence     @default(NONE)
  recurrenceDays      Int[]          @default([]) // 1=lun … 7=dom (ISO), solo WEEKLY
  recurrenceUntil     DateTime?
  nextRunAt           DateTime                    // = scheduledAt al crear; el worker la recalcula
  status              ScheduleStatus @default(ACTIVE)
  attempts            Int            @default(0)  // de la ocurrencia actual
  lastError           String?
  claimedAt           DateTime?                   // claim del worker (§17); NULL cuando no está en proceso
  createdAt           DateTime       @default(now())
  updatedAt           DateTime       @updatedAt
  logs                MessageLog[]
  @@index([status, nextRunAt])
  @@index([userId, status])
}

// Una fila por cada envío real ejecutado (historial). Estados actualizados por webhooks.
model MessageLog {
  id                 String    @id @default(uuid())
  scheduledMessageId String
  scheduledMessage   ScheduledMessage @relation(fields: [scheduledMessageId], references: [id], onDelete: Cascade)
  runAt              DateTime
  status             LogStatus
  evolutionMessageId String?              // response.key.id — clave para matchear webhooks
  remoteJid          String
  error              String?
  sentAt             DateTime?
  deliveredAt        DateTime?
  readAt             DateTime?
  createdAt          DateTime  @default(now())
  @@index([evolutionMessageId])
}

// Opcional (debug): guardar webhooks crudos los primeros días; job de limpieza a 7 días.
model WebhookEventRaw {
  id           String   @id @default(uuid())
  instanceName String
  event        String
  payload      Json
  createdAt    DateTime @default(now())
  @@index([createdAt])
}
```

---

## 5. Integración con Evolution API v2 (`server/src/services/evolution.ts`)

Autenticación: header `apikey`. Hay **dos tipos de key** — la **global** (env de Evolution, `AUTHENTICATION_API_KEY`) para gestionar instancias (`/instance/*`), y la **key propia de cada instancia** (campo `hash` devuelto al crearla) para enviar mensajes. Ambas viven **solo en el servidor**, cifradas en DB; jamás se envían a las apps.

Al iniciar y en el botón "Probar conexión" del panel admin: `GET {base}/` — la respuesta raíz incluye `version`; validar que empiece con `2.`.

⚠️ `evolutionBaseUrl` será normalmente **`http://`** (ej. `http://evolution-api:8080` por red interna de Docker, o `http://IP:8080`). La validación con zod debe aceptar `http` y `https` por igual — es tráfico servidor→servidor dentro del VPS, donde HTTP es lo esperado. Nunca forzar `https` en este campo.

### 5.1 Crear instancia (vincular un número)

```http
POST {base}/instance/create
apikey: {GLOBAL_KEY}
{
  "instanceName": "u7f3k-personal",          // generado: u{shortid}-{slug(nombre)}
  "qrcode": true,
  "integration": "WHATSAPP-BAILEYS",
  "rejectCall": false,
  "groupsIgnore": false,
  "alwaysOnline": false,
  "readMessages": false,
  "readStatus": false,
  "syncFullHistory": false,
  "webhook": {
    "url": "http://crona:3000/webhooks/evolution/{WEBHOOK_SECRET}",
    "byEvents": false,
    "base64": false,
    "events": ["QRCODE_UPDATED", "CONNECTION_UPDATE", "MESSAGES_UPDATE", "SEND_MESSAGE"]
  }
}
```

Respuesta: incluye `hash` (la apikey de la instancia → cifrar y guardar en `Instance.tokenEnc`) y `qrcode.base64` (data-URI PNG para mostrar en la app).

- La URL del webhook usa la **red interna de Docker** (`http://crona:3000/...`) — nunca necesita exponerse a internet.
- Si el QR expira: `GET {base}/instance/connect/{instanceName}` devuelve uno nuevo (campos `base64` y/o `code`; manejar ambos). Evolution además emite `QRCODE_UPDATED` por webhook → reenviar por WebSocket a la app para refrescar el QR en vivo.
- Estado: `GET {base}/instance/connectionState/{instanceName}` → `{ instance: { state: "open" | "connecting" | "close" } }`. `open` = CONNECTED.
- Desvincular: `DELETE {base}/instance/logout/{instanceName}`; eliminar: `DELETE {base}/instance/delete/{instanceName}`.

### 5.2 Enviar texto

```http
POST {base}/message/sendText/{instanceName}
apikey: {INSTANCE_KEY}
{
  "number": "5939XXXXXXXX",     // contacto: dígitos con código de país, SIN "+"
                                 // grupo: el JID completo "120363...@g.us"
  "text": "Hola!",
  "delay": 1800                  // ms; simula "escribiendo..." antes de enviar
}
```

Respuesta: `{ "key": { "remoteJid": "...", "fromMe": true, "id": "BAE5..." }, "messageTimestamp": "...", "status": "PENDING" }` → guardar `key.id` en `MessageLog.evolutionMessageId`.

⚠️ **Regla de destinatario:** si el mensaje se creó desde el picker (cache `Recipient`), usar **siempre el `jid` guardado** tal cual como `number`. Solo construir el número a mano si el usuario lo tipeó manualmente.

### 5.3 Enviar foto / video / documento

```http
POST {base}/message/sendMedia/{instanceName}
apikey: {INSTANCE_KEY}
{
  "number": "5939XXXXXXXX",
  "mediatype": "image",          // "image" | "video" | "document"
  "mimetype": "image/jpeg",
  "caption": "Mira esto",
  "media": "<BASE64_PURO o URL>",
  "fileName": "foto.jpg",
  "delay": 1800
}
```

Reglas críticas (errores reales de producción documentados por la comunidad):

1. **Base64 PURO**: sin prefijo `data:image/jpeg;base64,` y sin saltos de línea — con prefijo devuelve **400**.
2. **Archivos ≤ 3 MB** → enviar como base64. **> 3 MB (videos sobre todo)** → enviar como **URL**. Crona genera una **URL interna firmada de un solo uso** (`http://crona:3000/internal/media/{signedToken}`, TTL 15 min, solo válida en la red Docker) que Evolution puede descargar sin exponer archivos públicamente.
3. Timeout HTTP del cliente Evolution para media: **180 s**.
4. Límites de subida en Crona: imagen ≤ 16 MB, video ≤ 64 MB (`sharp` NO necesario; validar solo mimetype y tamaño). Advertir en la UI que videos > 16 MB pueden fallar en WhatsApp.

### 5.4 Contactos y grupos (sincronización del cache `Recipient`)

**Contactos** — `POST {base}/chat/findContacts/{instanceName}` con body `{ "where": {} }`. ⚠️ Devuelve mezclados contactos reales, grupos y **participantes de grupos**. Filtrar: conservar solo `id` que termina en `@s.whatsapp.net` (descartar `@g.us`, `@lid`, `@broadcast`) y que tenga nombre (`pushName`/`name`). Mapear a `Recipient(kind: CONTACT)` con `displayName`, `phoneNumber` (parte numérica del JID) y `profilePicUrl` si viene.

**Grupos** — `GET {base}/group/fetchAllGroups/{instanceName}?getParticipants=false` → array de `{ id: "1203...@g.us", subject, pictureUrl, size }`. ⚠️ Bug conocido: algunos grupos vienen **sin `subject`** — descartarlos del picker (o mostrar "Grupo sin nombre" si el usuario ya les programó algo antes).

Sincronizar: al conectar una instancia por primera vez y con el endpoint manual `POST /instances/:id/sync`. Upsert por `(instanceId, jid)`; no borrar los que desaparecen (mensajes programados pueden referenciarlos).

### 5.5 Webhooks entrantes (`POST /webhooks/evolution/:secret`)

Validar `:secret` contra `WEBHOOK_SECRET`. El payload trae `event`, `instance` y `data`. Los primeros días, guardar el JSON crudo en `WebhookEventRaw` para calibrar el mapeo.

| Evento | Acción en Crona |
|---|---|
| `connection.update` / `CONNECTION_UPDATE` | Actualizar `Instance.status` (`open`→CONNECTED, `close`→DISCONNECTED, `connecting`→CONNECTING). Si pasa a DISCONNECTED: **ntfy prioridad alta** ("Tu WhatsApp se desconectó — los mensajes programados fallarán") + broadcast WS |
| `qrcode.updated` / `QRCODE_UPDATED` | Reenviar QR nuevo por WS al usuario dueño de la instancia (pantalla de vinculación en vivo) |
| `messages.update` / `MESSAGES_UPDATE` | Buscar `MessageLog` por `data.keyId` / `data.key.id`. Mapear ack → estado (tabla abajo). Actualizar `deliveredAt`/`readAt`, broadcast WS |
| `send.message` / `SEND_MESSAGE` | Confirmación de salida; si el log sigue en SENDING, pasarlo a SENT |

Mapeo de acks (Baileys usa números o strings según versión — **soportar ambos**):

| Ack | Estado `MessageLog` |
|---|---|
| `2` / `SERVER_ACK` | SENT |
| `3` / `DELIVERY_ACK` | DELIVERED |
| `4` / `READ` | READ |

Nota de expectativas (documentar en la UI): "entregado" es confiable; "leído" depende de la configuración de privacidad del destinatario, y en **grupos** los acks agregados son limitados — mostrar hasta DELIVERED en grupos.

---

## 6. API REST de Crona (`server/src/routes/`)

Todas las rutas (salvo auth y webhooks) requieren `Authorization: Bearer {accessJWT}`. Validación de bodies con **zod**. Errores JSON: `{ error: { code, message } }`.

### Auth
| Método | Ruta | Descripción |
|---|---|---|
| POST | `/auth/register` | `{ email, password, name, inviteCode? }`. Si no existe ningún usuario → crea ADMIN sin invitación. Si ya existen → `inviteCode` obligatorio y válido |
| POST | `/auth/login` | → `{ accessToken (15 min), refreshToken (30 días), user }` |
| POST | `/auth/refresh` | Rotación: invalida el refresh usado, emite par nuevo |
| POST | `/auth/logout` | Revoca el refresh token |

### Usuario y Admin
| Método | Ruta | Descripción |
|---|---|---|
| GET / PATCH | `/me` | Perfil; PATCH permite `name`, `ntfyTopic`, `ntfyToken`, `notifyOnSent`, `password` |
| GET / PUT | `/admin/settings` | (ADMIN) `evolutionBaseUrl`, `evolutionGlobalApiKey` (write-only: nunca se devuelve en claro), `ntfyBaseUrl` |
| POST | `/admin/settings/test` | (ADMIN) Prueba `GET {base}/` de Evolution y devuelve `{ ok, version }` |
| GET | `/admin/users` · POST `/admin/invites` | (ADMIN) Listar usuarios; crear código de invitación (expira 7 días) |

### Instancias
| Método | Ruta | Descripción |
|---|---|---|
| GET | `/instances` | Instancias del usuario con estado |
| POST | `/instances` | `{ name }` → crea en Evolution (5.1), devuelve `{ instance, qrBase64 }` |
| GET | `/instances/:id/qr` | Re-solicita QR (`/instance/connect`) |
| GET | `/instances/:id/status` | Consulta `connectionState` en vivo y sincroniza el campo local |
| POST | `/instances/:id/sync` | Refresca cache de contactos y grupos (5.4) |
| DELETE | `/instances/:id` | Logout + delete en Evolution + borrado local |

### Destinatarios
| GET | `/instances/:id/recipients?kind=CONTACT|GROUP&search=texto` | Cache paginado, ordenado por `displayName` |

### Media
| Método | Ruta | Descripción |
|---|---|---|
| POST | `/media` | multipart (`file`); valida tipo/tamaño; guarda en `MEDIA_DIR/{userId}/{uuid}.{ext}` → `{ mediaId, ... }` |
| GET | `/media/:id` | Descarga autenticada (preview en la app; solo dueño) |
| GET | `/internal/media/:signedToken` | **Sin auth de usuario** — token HMAC firmado de un solo uso, TTL 15 min. Solo lo consume Evolution por red interna |

### Mensajes programados
| Método | Ruta | Descripción |
|---|---|---|
| GET | `/messages?filter=upcoming\|history&cursor=` | `upcoming`: ScheduledMessage ACTIVE/PAUSED ordenados por `nextRunAt`. `history`: MessageLogs del usuario, más recientes primero |
| POST | `/messages` | Crear (body abajo) |
| GET | `/messages/:id` | Detalle + logs |
| PATCH | `/messages/:id` | Solo si status ∈ {ACTIVE, PAUSED} y `nextRunAt > now()+60s`. Editables: body, mediaId, scheduledAt, recurrencia, pausa |
| POST | `/messages/:id/cancel` | → CANCELLED |
| POST | `/messages/:id/duplicate` | Copia lista para editar |
| DELETE | `/messages/:id` | Solo CANCELLED/COMPLETED/FAILED (limpieza) |

Body de creación:

```json
{
  "instanceId": "uuid",
  "recipient": { "jid": "1203...@g.us", "name": "Familia Vivar Barrera", "kind": "GROUP", "pictureUrl": null },
  "type": "IMAGE",
  "body": "Feliz cumple! 🎉",
  "mediaId": "uuid | null",
  "scheduledAt": "2026-07-20T14:00:00-05:00",
  "timezone": "America/Guayaquil",
  "recurrence": "NONE | DAILY | WEEKLY | MONTHLY",
  "recurrenceDays": [1, 3, 5],
  "recurrenceUntil": "2026-12-31T23:59:59-05:00"
}
```

Validaciones: `scheduledAt` mínimo `now()+60s`; si `type != TEXT` → `mediaId` obligatorio; si `WEEKLY` → `recurrenceDays` no vacío; el `recipient.jid` debe pertenecer a una instancia del usuario.

### Tiempo real
`GET /ws?token={accessJWT}` — WebSocket. El hub agrupa conexiones por `userId` y emite:

```json
{ "type": "message.updated",  "payload": { ScheduledMessage } }
{ "type": "log.updated",      "payload": { MessageLog } }
{ "type": "instance.updated", "payload": { Instance } }
{ "type": "qr.updated",       "payload": { "instanceId": "...", "qrBase64": "..." } }
```

Las apps además re-sincronizan con un `GET /messages` al volver a primer plano (el WS es mejora, no requisito de consistencia).

---

## 7. Worker / Scheduler (`server/src/services/scheduler.ts`)

Corre en el **mismo proceso** que la API (esta escala no necesita más). Loop `setInterval` 30 s + ejecución inmediata al arrancar.

```ts
// Pseudocódigo del tick
const claimed = await prisma.$queryRaw`
  SELECT id FROM "ScheduledMessage"
  WHERE status = 'ACTIVE' AND "nextRunAt" <= now()
  ORDER BY "nextRunAt"
  FOR UPDATE SKIP LOCKED
  LIMIT 10`;                                   // claim: setear "claimedAt" en la misma transacción (código exacto en §17)

for (const [i, msg] of claimed.entries()) {
  await sleep(i === 0 ? 0 : 3000 + rand(0, 9000));   // jitter anti-ban entre mensajes del mismo tick

  const state = await evolution.connectionState(msg.instance);   // cache 60 s por instancia
  if (state !== 'open') { await failOccurrence(msg, 'INSTANCIA_DESCONECTADA'); continue; }

  const log = await createLog(msg, 'SENDING');
  try {
    const res = msg.type === 'TEXT'
      ? await evolution.sendText(msg.instance, { number: msg.recipientJid, text: msg.body, delay: 1800 })
      : await evolution.sendMedia(msg.instance, buildMediaPayload(msg));   // base64 ≤3MB, URL firmada >3MB
    await markLog(log, 'SENT', res.key?.id);
    await onOccurrenceSuccess(msg);            // ver abajo
    await ntfy.maybeNotifySent(msg);           // solo si user.notifyOnSent
  } catch (e) {
    await markLog(log, 'FAILED', undefined, errMsg(e));
    await onOccurrenceFailure(msg, e);         // reintentos
  }
}
```

**Éxito de la ocurrencia** (`onOccurrenceSuccess`): `attempts = 0`, `lastError = null`. Si `recurrence = NONE` → `status = COMPLETED`. Si es recurrente → calcular la **próxima ocurrencia en la zona horaria del mensaje** con Luxon (DAILY: +1 día a la misma hora local; WEEKLY: siguiente día habilitado en `recurrenceDays`; MONTHLY: mismo día del mes siguiente, con clamp al último día si no existe, ej. 31 → 30 abr) y setear `nextRunAt`. Si supera `recurrenceUntil` → COMPLETED.

**Fallo** (`onOccurrenceFailure`): `attempts++`, `lastError`. Backoff: reintento 1 a **+2 min**, reintento 2 a **+10 min** (ajustando `nextRunAt`). Al **3er fallo**: notificar por **ntfy (prioridad alta)**; si `NONE` → `status = FAILED`; si es recurrente → registrar la ocurrencia fallida, `attempts = 0` y saltar a la siguiente ocurrencia.

**Idempotencia**: el claim con `SKIP LOCKED` + marcar antes de enviar garantiza que **nunca se envía dos veces**, incluso con reinicios (peor caso tras un crash a mitad de envío: un log queda en SENDING → job de arranque lo marca FAILED con error `INTERRUMPIDO` para revisión manual; preferible a duplicar un mensaje de WhatsApp).

---

## 8. Notificaciones ntfy (`server/src/services/ntfy.ts`)

`POST {ntfyBaseUrl}/{user.ntfyTopic}` con headers `Title`, `Priority`, `Tags` (y `Authorization: Bearer {ntfyToken}` si está configurado).

| Evento | Cuándo | Prioridad |
|---|---|---|
| ❌ Mensaje falló (3 intentos) | Siempre | `high` — "No se envió tu mensaje a {nombre}: {error}" |
| 🔌 Instancia desconectada | Siempre | `high` — "WhatsApp ({instancia}) se desconectó. Ábrela en Crona y re-escanea el QR" |
| ✅ Mensaje enviado | Solo si `notifyOnSent` | `default` — "Enviado a {nombre} · {hora local}" |

Setup del usuario (documentar en el README y en la pantalla de Ajustes): instalar la app **ntfy** del App Store, suscribirse a su topic. Si el server ntfy es **self-hosted**, el `server.yml` de ntfy debe incluir `upstream-base-url: "https://ntfy.sh"` para que el push llegue a iOS vía APNs. El topic funciona como secreto: generarlo aleatorio (`crona-{nombre}-{6 chars}`).

---

## 9. Apps SwiftUI (iOS + macOS) — `app/`

### 9.1 Proyecto

- **XcodeGen** (`brew install xcodegen`): definir todo en `project.yml` — un target multiplataforma `Crona` con `destinations: [iOS, macOS]`, deployment iOS 17.0 / macOS 14.0, bundle id `com.sebastian.crona`. Claude Code edita `project.yml` y Sources; el usuario corre `xcodegen generate` y abre el `.xcodeproj`.
- ⚠️ **Firma con Personal Team gratuito (sideload):** NO agregar capabilities. **Prohibido** `aps-environment`, Push Notifications, iCloud, App Groups — el build falla al firmar. El perfil expira a los **7 días** (redeploy desde Xcode); esto **no afecta los envíos** porque los hace el servidor.
- Solo se necesita la capability por defecto de red saliente en macOS (`com.apple.security.network.client` en el sandbox).
- **ATS (App Transport Security)**: como el servidor Crona puede ser `http://`, el `project.yml` debe generar el Info.plist con `NSAppTransportSecurity → NSAllowsArbitraryLoads: true` (en XcodeGen: bloque `info.properties` del target). Sin esto, iOS/macOS **bloquean silenciosamente** todo request cleartext y parece un error de red genérico.
- `ServerSetupView` acepta URLs `http://` mostrando una advertencia suave ("conexión sin cifrar — úsala solo si confías en la red o vas por VPN"), y `WebSocketClient` usa `ws://` o `wss://` según el esquema del servidor configurado.

### 9.2 Arquitectura de la app

MVVM ligero con `@Observable` (Observation framework) + `async/await`:

```
Sources/
├── App/CronaApp.swift          # @main; en macOS agrega MenuBarExtra
├── Core/
│   ├── APIClient.swift            # actor; URLSession, JSON, refresh automático de token en 401
│   ├── Models.swift               # Codable espejo de la API (User, Instance, Recipient, ScheduledMessage, MessageLog…)
│   ├── Keychain.swift             # guarda serverURL + refreshToken (kSecClassGenericPassword)
│   ├── WebSocketClient.swift      # URLSessionWebSocketTask, reconexión con backoff
│   └── SessionStore.swift         # @Observable: sesión, instancia activa, cache en memoria
├── Features/
│   ├── Onboarding/ServerSetupView.swift   # 1ª vez: URL del servidor Crona → /health
│   ├── Auth/LoginView.swift · RegisterView.swift (con campo código de invitación)
│   ├── Instances/InstanceListView · CreateInstanceView · QRLinkView (QR en vivo vía WS)
│   ├── Schedule/
│   │   ├── ScheduledListView.swift        # pantalla principal
│   │   ├── ComposeView.swift              # flujo de creación
│   │   ├── RecipientPickerView.swift
│   │   ├── ScheduleSheet.swift            # fecha/hora + recurrencia
│   │   └── MessageDetailView.swift
│   ├── History/HistoryView.swift
│   └── Settings/SettingsView · AdminSettingsView · NtfySettingsView
└── Platform/macOS/MenuBarView.swift
```

### 9.3 UI — estilo WhatsApp (referencia: capturas del usuario en Mac e iPhone)

**Estructura de navegación**
- **macOS**: `NavigationSplitView` — sidebar izquierda con la lista (como WhatsApp Desktop: fila = avatar circular 44 pt, nombre en bold, preview del mensaje en gris, hora/fecha a la derecha en verde, badge de estado), detalle a la derecha; placeholder centrado con el logo cuando no hay selección. Barra lateral fina de iconos (Programados / Historial / Ajustes) opcional con `List` + secciones si simplifica.
- **iOS**: `TabView` con 3 tabs — **Programados**, **Historial**, **Ajustes**. Título grande "Programados", search bar, y chips de filtro horizontales estilo WhatsApp iOS: `Todos · Contactos · Grupos · Recurrentes`.

**Fila de mensaje programado** (ambas plataformas): avatar (AsyncImage con iniciales de fallback), nombre del destinatario, preview (texto o "📷 Foto" / "🎥 Video" + caption), y a la derecha la **hora de envío** ("Hoy 5:00 PM", "Mañana 9:00 AM", "Vie 20 Jun") en verde `Color.green` + icono de estado. Recurrentes muestran 🔁 junto a la hora.

**Iconos de estado** (SF Symbols): `clock` programado · `checkmark` enviado · `checkmark.circle` entregado (doble check) · doble check azul = leído (`.foregroundStyle(.blue)`) · `exclamationmark.circle.fill` rojo = fallido · `pause.circle` pausado.

**ComposeView (flujo)**: (1) elegir instancia si hay varias → (2) `RecipientPickerView`: segmented Contactos/Grupos + búsqueda + lista con avatares, botón "Sincronizar" → (3) editor: burbuja de preview estilo chat, `TextField` multilinea con fondo tipo composer de WhatsApp, botón 📎 → `PhotosPicker` (iOS) / `fileImporter` (macOS) con thumbnail del adjunto → (4) `ScheduleSheet`: chips rápidos ("En 1 hora", "Esta noche 8 PM", "Mañana 9 AM") + `DatePicker` completo + selector de recurrencia (Ninguna/Diaria/Semanal con días/Mensual + "hasta") → (5) confirmación con resumen. Subir media a `POST /media` **antes** de crear el mensaje, con `ProgressView`.

**Tema**: acento verde WhatsApp‑like `#25D366` / modo oscuro fiel a la captura (fondos `#111B21`-ish vía colores semánticos). **No** usar el logo ni assets de WhatsApp — inspiración de layout, no copia de marca.

### 9.4 macOS extra — Menu bar

`MenuBarExtra("Crona", systemImage: "paperplane.circle")`: próximos 5 envíos + botón "Nuevo mensaje" + estado de la instancia. Mientras la app corre, el `WebSocketClient` dispara **notificaciones locales** (`UNUserNotificationCenter` — permitido sin cuenta paga) en enviado/fallido/desconexión. En iPhone las notificaciones llegan por **ntfy**.

### 9.5 Sincronización

Fuente de verdad = servidor. La app: fetch al aparecer cada pantalla + al volver a foreground (`scenePhase`), WS para updates en vivo, updates optimistas al crear/cancelar con rollback si falla. Sin base de datos local en v1 (cache en memoria del `SessionStore`).

---

## 10. Despliegue en el VPS

### 10.1 `docker-compose.yml`

```yaml
services:
  crona:
    build: ./server
    container_name: crona
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data/media:/data/media
    networks: [evolution-net]
    # expuesto solo vía reverse proxy

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
    networks: [evolution-net]

networks:
  evolution-net:
    external: true          # ⚠️ nombre real de la red del compose de Evolution (`docker network ls`)

volumes:
  caddy_data:
```

`Caddyfile`:

```
crona.TUDOMINIO.com {
    reverse_proxy crona:3000
}
```

**Opción B — solo HTTP (sin dominio ni TLS)**: omitir el servicio `caddy` y exponer el puerto directo en `crona`:

```yaml
    ports: ["3000:3000"]
```

Las apps se conectan a `http://IP_DEL_VPS:3000` (la excepción ATS de 9.1 lo permite). ⚠️ Con HTTP los JWT y el contenido viajan en claro por internet: aceptable para arrancar, pero el README debe recomendar tres upgrades posibles — Caddy con dominio (TLS automático, 3 líneas), Cloudflare Tunnel apuntando a `crona:3000` (sin abrir puertos), o meter VPS + dispositivos en un tailnet (Tailscale) y conectarse por la IP privada.

### 10.2 `.env.example`

```bash
DATABASE_URL=postgresql://user:pass@postgres:5432/crona   # host = servicio Postgres de Evolution
JWT_SECRET=                    # openssl rand -hex 32
ENCRYPTION_KEY=                # openssl rand -hex 32  (AES-256-GCM para keys de Evolution)
WEBHOOK_SECRET=                # openssl rand -hex 24
MEDIA_DIR=/data/media
PUBLIC_URL=https://crona.TUDOMINIO.com   # u http://IP_DEL_VPS:3000 en despliegue Opción B
INTERNAL_URL=http://crona:3000        # para URLs de media firmadas y webhook
PORT=3000
TZ=America/Guayaquil
```

Primer arranque: `npx prisma migrate deploy`. Crear la base: `CREATE DATABASE crona;` en el Postgres existente (documentar el comando `docker exec` exacto en el README).

### 10.3 Seguridad

argon2id para contraseñas · JWT access 15 min + refresh rotativo 30 días (hash en DB) · rate limit en `/auth/*` (10/min/IP) · keys de Evolution cifradas AES-256-GCM y write-only por API · media servida solo al dueño; URLs internas firmadas HMAC de un solo uso · HTTPS recomendado (HTTP soportado — Opción B en 10.1) · sin CORS (clientes nativos) · headers de Fastify helmet.

---

## 11. Plan de implementación por fases (ejecutar en orden)

Cada fase termina con la app/servidor **corriendo** y un commit. Probar con `curl` antes de pasar a la siguiente.

- **Fase 0 — Scaffold**: monorepo, server Fastify + Prisma + migración inicial, `/health`, Dockerfile, compose. ✔ `curl /health` responde.
- **Fase 1 — Auth + Admin**: registro (1º = ADMIN), login/refresh/logout, invitaciones, `ServerSettings` con cifrado, `POST /admin/settings/test` contra Evolution real. ✔ Test devuelve `{ ok: true, version: "2.x" }`.
- **Fase 2 — Instancias**: crear con webhook interno, QR, connectionState, sync de contactos/grupos con filtros de 5.4, receptor de webhooks (guardar crudos) + `CONNECTION_UPDATE`. ✔ Se vincula un número real escaneando el QR devuelto y `/instances/:id/recipients` lista contactos y grupos.
- **Fase 3 — Mensajes de texto programados**: CRUD `/messages`, worker completo (claim, jitter, connectionState, reintentos, recurrencia), `MessageLog`, mapeo de acks `MESSAGES_UPDATE`. ✔ Un texto programado a +2 min llega al WhatsApp destino y su log pasa a DELIVERED.
- **Fase 4 — Media**: upload, storage, URL interna firmada, `sendMedia` (base64 ≤3 MB / URL >3 MB). ✔ Foto y video programados llegan correctamente.
- **Fase 5 — ntfy + WS**: servicio ntfy con los 3 eventos, hub WebSocket con broadcasts. ✔ Al fallar un envío forzado llega push al iPhone vía app ntfy.
- **Fase 6 — App SwiftUI núcleo**: project.yml + Onboarding/Login → Instancias con QR en vivo → lista Programados → Compose completo (contacto/grupo, media, fecha/hora, recurrencia) → Detalle/cancelar/editar → Historial → Ajustes (+ panel admin). ✔ Flujo completo desde iPhone y Mac contra el servidor real.
- **Fase 7 — Pulido**: MenuBarExtra + notificaciones locales macOS, filtros/búsqueda, estados vacíos, manejo de instancia desconectada en UI, README de despliegue y de setup ntfy.

## 12. Criterios de aceptación finales

1. Programo un mensaje en la **Mac** y aparece en el **iPhone** (y viceversa) sin acción manual.
2. Con **ambas apps cerradas**, el mensaje se envía a la hora exacta (±30 s) a un **contacto** y a un **grupo**.
3. Puedo enviar **texto, foto y video** (video > 3 MB incluido).
4. Puedo **crear una instancia**, escanear el **QR** desde la app y ver el estado de conexión.
5. La **configuración de Evolution** (URL + key global) se hace desde la app (rol ADMIN) y se puede probar.
6. Mensajes **recurrentes** diario/semanal/mensual se re-programan solos tras cada envío.
7. El **historial** muestra enviado → entregado → leído (leído cuando el destinatario lo permite).
8. Si un envío **falla** o la instancia **se desconecta**, recibo push por **ntfy** en el iPhone.
9. Puedo **editar/cancelar/duplicar** un mensaje pendiente.
10. **Multiusuario**: un segundo usuario entra con invitación y solo ve sus instancias y mensajes.

## 13. Gotchas conocidos (leer antes de codear)

1. Base64 **sin** prefijo `data:` ni saltos de línea → si no, 400.
2. Videos > 3 MB por **URL interna firmada**, no base64. Timeout media: 180 s.
3. `findContacts` mezcla participantes de grupos y JIDs `@lid` → filtrar (5.4).
4. `fetchAllGroups` puede traer grupos **sin `subject`** → descartarlos del picker.
5. Enviar a grupos usando el **JID completo `@g.us`** como `number`.
6. Key **global** para `/instance/*`, key **de instancia** para `/message/*` — no mezclarlas.
7. Hay versiones 2.x con un bug donde `sendText` responde **400 pero el mensaje sí sale** (error de Prisma interno de Evolution): si la respuesta de error contiene `key.id`, tratarla como éxito y loggear warning.
8. Riesgo de ban (Baileys es no-oficial): mantener `delay` 1500–3000 ms, jitter entre mensajes del mismo tick, y no programar ráfagas masivas. Crona es uso personal — documentarlo.
9. El nombre de la red Docker de Evolution varía según su compose: verificar con `docker network ls` antes del primer deploy.
10. Payloads de webhook varían levemente entre 2.x → handler tolerante + `WebhookEventRaw` los primeros días.
11. **ATS**: si el servidor es `http://` y falta la excepción del 9.1, la app falla con "App Transport Security has blocked a cleartext HTTP connection" — el error solo se ve en la consola de Xcode; en la UI parece que "no hay internet".

## 14. Cómo trabajar este documento (instrucción para Claude Code)

Guarda este archivo como `SPEC.md` en la raíz del repo y **copia la sección 20 como `CLAUDE.md`**. Implementa **fase por fase** (sección 11), commit al cerrar cada una con su criterio ✔ verificado. Backend primero (Fases 0–5, probando con `curl` contra la Evolution API real del usuario), apps después. Registra cualquier desviación en `DECISIONS.md`.

Los apéndices **§15–§20 son normativos**: el contrato JSON de §15 define exactamente los `Codable` de Swift; las implementaciones de referencia de §17 y §18 se usan tal cual (solo adaptando imports); el runbook de §19 debe quedar reflejado en el README del repo.

---

# APÉNDICES NORMATIVOS

## 15. Contrato JSON de la API (fuente de verdad para los `Codable` de Swift)

Convenciones globales — el server **siempre** cumple esto y los modelos Swift se escriben espejo:

- Claves en **camelCase**. Enums como **strings en MAYÚSCULAS** tal como Prisma (`"ACTIVE"`, `"GROUP"`, `"IMAGE"`…).
- Fechas: el server **emite** ISO-8601 UTC con milisegundos y `Z` (`"2026-07-20T19:00:00.000Z"`); **acepta** entradas con offset (`"2026-07-20T14:00:00-05:00"`).
- Listas paginadas: `{ "items": [...], "nextCursor": "opaque-string" | null }` (query `?cursor=`).
- Errores (siempre): `{ "error": { "code": "SNAKE_CODE", "message": "texto en español para mostrar en UI" } }`.

C�digos de error: `INVALID_CREDENTIALS`, `INVITE_REQUIRED`, `INVITE_INVALID`, `TOKEN_EXPIRED`, `FORBIDDEN`, `NOT_FOUND`, `VALIDATION_ERROR`, `INSTANCE_DISCONNECTED`, `EVOLUTION_UNREACHABLE`, `MEDIA_TOO_LARGE`, `MEDIA_TYPE_UNSUPPORTED`, `MESSAGE_NOT_EDITABLE`, `RATE_LIMITED`.

### Objetos

```jsonc
// User
{ "id": "uuid", "email": "s@x.com", "name": "Sebastián", "role": "ADMIN",
  "ntfyTopic": "crona-seb-a8k2x1", "notifyOnSent": false, "createdAt": "…Z" }

// POST /auth/login y POST /auth/register → 200/201
{ "accessToken": "jwt", "refreshToken": "opaque", "user": { User } }
// POST /auth/refresh → 200
{ "accessToken": "jwt", "refreshToken": "opaque" }

// Instance
{ "id": "uuid", "name": "Personal", "instanceName": "u7f3k-personal",
  "phoneNumber": "5939XXXXXXXX" , "profilePicUrl": null,
  "status": "CONNECTED", "lastConnectedAt": "…Z", "createdAt": "…Z" }

// POST /instances → 201
{ "instance": { Instance }, "qrBase64": "data:image/png;base64,…", "pairingCode": null }
// GET /instances/:id/qr → 200  →  { "qrBase64": "…", "pairingCode": "ABCD-1234" | null }
// POST /instances/:id/sync → 200  →  { "contacts": 214, "groups": 18 }

// Recipient
{ "id": "uuid", "jid": "5939XXXXXXXX@s.whatsapp.net", "displayName": "Rafael Ramirez",
  "pictureUrl": "https://…", "kind": "CONTACT", "phoneNumber": "5939XXXXXXXX" }

// POST /media → 201
{ "mediaId": "uuid", "fileName": "foto.jpg", "mimeType": "image/jpeg", "sizeBytes": 234567 }

// ScheduledMessage
{ "id": "uuid", "instanceId": "uuid",
  "recipientJid": "1203…@g.us", "recipientName": "Familia Vivar Barrera",
  "recipientKind": "GROUP", "recipientPictureUrl": null,
  "type": "IMAGE", "body": "Feliz cumple 🎉", "mediaId": "uuid",
  "timezone": "America/Guayaquil", "scheduledAt": "…Z",
  "recurrence": "NONE", "recurrenceDays": [], "recurrenceUntil": null,
  "nextRunAt": "…Z", "status": "ACTIVE", "attempts": 0, "lastError": null,
  "createdAt": "…Z", "updatedAt": "…Z" }

// MessageLog
{ "id": "uuid", "scheduledMessageId": "uuid", "runAt": "…Z", "status": "DELIVERED",
  "evolutionMessageId": "BAE5…", "remoteJid": "…", "error": null,
  "sentAt": "…Z", "deliveredAt": "…Z", "readAt": null }

// HistoryItem — lo que devuelve GET /messages?filter=history (log enriquecido con snapshot del padre)
{ "id": "logUuid", "scheduledMessageId": "uuid", "runAt": "…Z", "status": "READ",
  "recipientName": "Daniela Prado", "recipientKind": "CONTACT", "recipientPictureUrl": null,
  "type": "TEXT", "body": "Hoy voy", "error": null }

// GET /messages/:id → 200
{ "message": { ScheduledMessage }, "logs": [ MessageLog ] }

// GET /admin/settings → 200 (la key NUNCA vuelve en claro)
{ "evolutionBaseUrl": "http://evolution-api:8080", "evolutionGlobalApiKeySet": true, "ntfyBaseUrl": "https://ntfy.sh" }
// POST /admin/settings/test → 200 → { "ok": true, "version": "2.2.3" }
```

Media aceptado en `POST /media` (campo multipart `file`): `image/jpeg`, `image/png`, `image/webp` (≤ 16 MB) · `video/mp4`, `video/quicktime` (≤ 64 MB) · `application/pdf` (≤ 64 MB, se envía como `document`). Mapeo a Evolution: `image/*`→`image`, `video/*`→`video`, `application/pdf`→`document`.

---

## 16. Backend — configuración exacta

### 16.1 `server/package.json`

```json
{
  "name": "crona-server",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "migrate:dev": "prisma migrate dev",
    "migrate:deploy": "prisma migrate deploy"
  },
  "dependencies": {
    "fastify": "^5",
    "@prisma/client": "^6",
    "argon2": "^0.41",
    "jose": "^5",
    "luxon": "^3",
    "nanoid": "^5",
    "pino": "^9",
    "zod": "^3"
  },
  "devDependencies": {
    "prisma": "^6",
    "tsx": "^4",
    "typescript": "^5",
    "@types/node": "^22",
    "@types/luxon": "^3"
  }
}
```

Instalar además los plugins de Fastify en su **última versión compatible con Fastify 5** (no pinear a mano): `npm i @fastify/helmet @fastify/multipart @fastify/rate-limit @fastify/websocket`.

### 16.2 `server/tsconfig.json`

```json
{ "compilerOptions": { "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext",
  "strict": true, "outDir": "dist", "rootDir": "src", "esModuleInterop": true, "skipLibCheck": true } }
```

### 16.3 `server/Dockerfile` (usar `node:20-slim`, NO alpine — argon2 y Prisma dan problemas con musl)

```dockerfile
FROM node:20-slim AS build
RUN apt-get update -y && apt-get install -y openssl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY prisma ./prisma
RUN npx prisma generate
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-slim
RUN apt-get update -y && apt-get install -y openssl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY prisma ./prisma
RUN npx prisma generate
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/index.js"]
```

### 16.4 `src/config.ts` — env validado con zod

```ts
import { z } from "zod";
const Env = z.object({
  DATABASE_URL: z.string().min(1),
  JWT_SECRET: z.string().min(32),
  ENCRYPTION_KEY: z.string().length(64),   // 32 bytes hex
  WEBHOOK_SECRET: z.string().min(16),
  MEDIA_DIR: z.string().default("/data/media"),
  PUBLIC_URL: z.string().min(1),
  INTERNAL_URL: z.string().default("http://crona:3000"),
  PORT: z.coerce.number().default(3000),
});
export const config = Env.parse(process.env);
```

### 16.5 Orden de arranque en `src/index.ts`

1. `config` (falla rápido si falta un secreto) → 2. Prisma connect → 3. `recoverOnBoot()` (§17.6) → 4. Fastify + plugins (helmet, rate-limit solo en `/auth/*`, multipart con `limits.fileSize = 64 MB`, websocket) → 5. registrar rutas → 6. `listen({ host: "0.0.0.0", port })` → 7. `scheduler.start()` (tick inmediato + `setInterval` 30 s). Proceso **único** (API + worker juntos): no escalar réplicas sin revisar §17.4.

---

## 17. Backend — implementaciones de referencia (usar tal cual)

### 17.1 `crypto.ts` — AES-256-GCM para las keys de Evolution

```ts
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { config } from "../config.js";
const KEY = Buffer.from(config.ENCRYPTION_KEY, "hex");

export function encrypt(plain: string): string {
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", KEY, iv);
  const enc = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  return [iv, c.getAuthTag(), enc].map(b => b.toString("base64")).join(".");
}
export function decrypt(payload: string): string {
  const [iv, tag, data] = payload.split(".").map(s => Buffer.from(s, "base64"));
  const d = createDecipheriv("aes-256-gcm", KEY, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(data), d.final()]).toString("utf8");
}
```

### 17.2 JWT y refresh tokens

```ts
import { SignJWT, jwtVerify } from "jose";
import { createHash, randomBytes } from "node:crypto";
const secret = new TextEncoder().encode(config.JWT_SECRET);

export const signAccess = (userId: string, role: string) =>
  new SignJWT({ role }).setProtectedHeader({ alg: "HS256" })
    .setSubject(userId).setIssuedAt().setExpirationTime("15m").sign(secret);

export const verifyAccess = (jwt: string) => jwtVerify(jwt, secret);   // lanza si expiró → 401 TOKEN_EXPIRED

export const newRefreshToken = () => randomBytes(48).toString("base64url");
export const hashToken = (t: string) => createHash("sha256").update(t).digest("hex");
// Al refrescar: buscar por hash, validar expiresAt/revokedAt, revocar el usado, emitir par nuevo (rotación).
```

### 17.3 URLs internas firmadas para media (un solo uso)

```ts
import { createHmac, timingSafeEqual } from "node:crypto";
const usedTokens = new Map<string, number>();                    // token → exp (epoch s)
setInterval(() => { const now = Date.now() / 1000;
  for (const [t, e] of usedTokens) if (e < now) usedTokens.delete(t); }, 60_000).unref();

export function signMediaToken(mediaId: string, ttlSec = 900): string {
  const exp = Math.floor(Date.now() / 1000) + ttlSec;
  const payload = Buffer.from(`${mediaId}.${exp}`).toString("base64url");
  const sig = createHmac("sha256", config.ENCRYPTION_KEY).update(payload).digest("base64url");
  return `${payload}.${sig}`;
}
export function consumeMediaToken(token: string): string | null {   // → mediaId | null
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return null;
  const expect = createHmac("sha256", config.ENCRYPTION_KEY).update(payload).digest("base64url");
  if (sig.length !== expect.length || !timingSafeEqual(Buffer.from(sig), Buffer.from(expect))) return null;
  const [mediaId, expStr] = Buffer.from(payload, "base64url").toString().split(".");
  const exp = Number(expStr);
  if (exp < Date.now() / 1000 || usedTokens.has(token)) return null;
  usedTokens.set(token, exp);
  return mediaId;
}
// URL que se pasa a Evolution: `${config.INTERNAL_URL}/internal/media/${signMediaToken(mediaId)}`
```

### 17.4 Claim del scheduler (idempotente, sobrevive reinicios)

```ts
export async function claimDue(limit = 10): Promise<string[]> {
  return prisma.$transaction(async (tx) => {
    const rows = await tx.$queryRaw<{ id: string }[]>`
      SELECT id FROM "ScheduledMessage"
      WHERE status = 'ACTIVE'
        AND "nextRunAt" <= now()
        AND ("claimedAt" IS NULL OR "claimedAt" < now() - interval '5 minutes')
      ORDER BY "nextRunAt" ASC
      FOR UPDATE SKIP LOCKED
      LIMIT ${limit}`;
    const ids = rows.map(r => r.id);
    if (ids.length) await tx.scheduledMessage.updateMany({
      where: { id: { in: ids } }, data: { claimedAt: new Date() } });
    return ids;
  });
}
// Al terminar cada ocurrencia (éxito o fallo definitivo): claimedAt = null.
// El umbral de 5 min re-libera claims de un proceso que crasheó a mitad del tick.
```

### 17.5 `recurrence.ts` — próxima ocurrencia en la zona del mensaje (Luxon)

```ts
import { DateTime } from "luxon";
type Msg = { recurrence: "DAILY" | "WEEKLY" | "MONTHLY"; recurrenceDays: number[];
             timezone: string; nextRunAt: Date };

export function nextOccurrence(m: Msg): Date {
  const cur = DateTime.fromJSDate(m.nextRunAt, { zone: m.timezone });
  if (m.recurrence === "DAILY")   return cur.plus({ days: 1 }).toJSDate();
  if (m.recurrence === "MONTHLY") return cur.plus({ months: 1 }).toJSDate(); // Luxon clampa: 31 ene → 28/29 feb
  const days = [...m.recurrenceDays].sort((a, b) => a - b);                  // ISO: 1=lun … 7=dom
  for (let i = 1; i <= 7; i++) {
    const cand = cur.plus({ days: i });
    if (days.includes(cand.weekday)) return cand.toJSDate();
  }
  return cur.plus({ days: 7 }).toJSDate();
}
```

### 17.6 Recuperación al arrancar

```ts
export async function recoverOnBoot() {
  await prisma.messageLog.updateMany({
    where: { status: "SENDING" },
    data: { status: "FAILED", error: "INTERRUMPIDO (reinicio del servidor)" } });
  await prisma.scheduledMessage.updateMany({
    where: { claimedAt: { not: null } }, data: { claimedAt: null } });
}
```

### 17.7 `evolution.ts` — cliente HTTP

```ts
async function evoFetch(path: string, opts: { method?: string; body?: unknown;
    apikey: string; timeoutMs?: number }) {
  const s = await getSettings();                       // ServerSettings desde DB (key desencriptada)
  const res = await fetch(new URL(path, s.evolutionBaseUrl), {
    method: opts.method ?? "GET",
    headers: { apikey: opts.apikey, "content-type": "application/json" },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    signal: AbortSignal.timeout(opts.timeoutMs ?? 30_000),
  });
  const json: any = await res.json().catch(() => null);
  if (!res.ok) {
    if (json?.key?.id ?? json?.response?.key?.id) return json;   // Gotcha 7: 400 pero el mensaje salió
    throw new EvolutionError(res.status, json);
  }
  return json;
}

export const evolution = {
  version:        ()            => evoFetch("/", { apikey: GLOBAL() }),
  createInstance: (body: any)   => evoFetch("/instance/create", { method: "POST", body, apikey: GLOBAL() }),
  connect:        (n: string)   => evoFetch(`/instance/connect/${n}`, { apikey: GLOBAL() }),
  state:          (n: string)   => evoFetch(`/instance/connectionState/${n}`, { apikey: GLOBAL() }),
  logout:         (n: string)   => evoFetch(`/instance/logout/${n}`, { method: "DELETE", apikey: GLOBAL() }),
  remove:         (n: string)   => evoFetch(`/instance/delete/${n}`, { method: "DELETE", apikey: GLOBAL() }),
  sendText:  (n: string, k: string, body: any) => evoFetch(`/message/sendText/${n}`,  { method: "POST", body, apikey: k }),
  sendMedia: (n: string, k: string, body: any) => evoFetch(`/message/sendMedia/${n}`, { method: "POST", body, apikey: k, timeoutMs: 180_000 }),
  findContacts:   (n: string, k: string) => evoFetch(`/chat/findContacts/${n}`, { method: "POST", body: { where: {} }, apikey: k }),
  fetchAllGroups: (n: string, k: string) => evoFetch(`/group/fetchAllGroups/${n}?getParticipants=false`, { apikey: k }),
};
// GLOBAL() lee ServerSettings y desencripta la key global. connectionState se cachea 60 s por instancia.
```

### 17.8 `ntfy.ts` — publicar en modo JSON (soporta tildes y emojis en el título)

```ts
export async function ntfyPublish(user: { ntfyTopic: string | null; ntfyToken: string | null },
    n: { title: string; message: string; priority?: number; tags?: string[] }) {
  if (!user.ntfyTopic) return;
  const s = await getSettings();
  await fetch(s.ntfyBaseUrl, {
    method: "POST",
    headers: { "content-type": "application/json",
      ...(user.ntfyToken ? { authorization: `Bearer ${user.ntfyToken}` } : {}) },
    body: JSON.stringify({ topic: user.ntfyTopic, title: n.title, message: n.message,
      priority: n.priority ?? 3, tags: n.tags ?? [] }),
  }).catch(err => log.warn({ err }, "ntfy publish failed"));   // ntfy NUNCA rompe un envío
}
// Prioridades: fallo de mensaje / instancia desconectada → 4 (high); enviado OK → 3 (default)
```

### 17.9 `ws/hub.ts`

```ts
const conns = new Map<string, Set<any>>();          // userId → sockets

export function register(userId: string, socket: any) {
  if (!conns.has(userId)) conns.set(userId, new Set());
  conns.get(userId)!.add(socket);
  socket.on("close", () => conns.get(userId)?.delete(socket));
}
export function broadcast(userId: string, type: string, payload: unknown) {
  const msg = JSON.stringify({ type, payload });
  conns.get(userId)?.forEach(s => s.readyState === 1 && s.send(msg));
}
// Ruta: GET /ws?token=… → verifyAccess(token) ANTES de register(); si falla, cerrar con 4401.
```

---

## 18. App SwiftUI — configuración exacta y esqueletos

### 18.1 `app/project.yml` (XcodeGen)

```yaml
name: Crona
options:
  bundleIdPrefix: com.sebastian
  deploymentTarget:
    iOS: "17.0"
    macOS: "14.0"
targets:
  Crona:
    type: application
    supportedDestinations: [iOS, macOS]
    sources: [Sources]
    info:
      path: Sources/Info.plist
      properties:
        CFBundleDisplayName: Crona
        NSAppTransportSecurity:            # servidor puede ser http:// (SPEC §2)
          NSAllowsArbitraryLoads: true
        UILaunchScreen: {}
        LSApplicationCategoryType: public.app-category.productivity
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.sebastian.crona
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": Sources/macOS.entitlements
        # DEVELOPMENT_TEAM se elige en Xcode → Signing (Personal Team). NO agregar más entitlements: firma gratuita.
```

`Sources/macOS.entitlements` (SOLO macOS — en iOS no debe existir ningún entitlements file):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
```

### 18.2 `Core/APIClient.swift`

```swift
import Foundation

enum APIError: Error { case notConfigured, http(Int), server(code: String, message: String) }

actor APIClient {
    static let shared = APIClient()
    private(set) var baseURL: URL?
    private var accessToken: String?

    func configure(baseURL: URL) { self.baseURL = baseURL }
    func setAccessToken(_ t: String?) { accessToken = t }

    static let decoder: JSONDecoder = {
        let withFrac = ISO8601DateFormatter(); withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter();   noFrac.formatOptions = [.withInternetDateTime]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let dt = withFrac.date(from: s) ?? noFrac.date(from: s) { return dt }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Fecha inválida: \(s)"))
        }
        return d
    }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    func request<T: Decodable, B: Encodable>(_ method: String, _ path: String,
        body: B? = nil as String?, query: [URLQueryItem] = [], retryOn401: Bool = true) async throws -> T {
        guard let baseURL else { throw APIError.notConfigured }
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try Self.encoder.encode(body)
                      req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        if status == 401, retryOn401 {
            try await refreshSession()
            return try await request(method, path, body: body, query: query, retryOn401: false)
        }
        guard (200..<300).contains(status) else {
            if let env = try? Self.decoder.decode(ErrorEnvelope.self, from: data) {
                throw APIError.server(code: env.error.code, message: env.error.message)
            }
            throw APIError.http(status)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    private func refreshSession() async throws {
        guard let rt = Keychain.get("refreshToken") else { throw APIError.http(401) }
        struct Body: Encodable { let refreshToken: String }
        struct Resp: Decodable { let accessToken: String; let refreshToken: String }
        let r: Resp = try await request("POST", "/auth/refresh", body: Body(refreshToken: rt), retryOn401: false)
        Keychain.set(r.refreshToken, for: "refreshToken")
        accessToken = r.accessToken
    }
}
struct ErrorEnvelope: Decodable { struct E: Decodable { let code: String; let message: String }; let error: E }
```

Subida de media: `multipart/form-data` manual (boundary + `Data`) con `URLSession.upload(for:from:)`; para video, `PhotosPicker` → `loadTransferable(type: Movie.self)` a URL temporal y leer por chunks. Imágenes: `loadTransferable(type: Data.self)`.

### 18.3 `Core/Keychain.swift`

```swift
import Security
import Foundation

enum Keychain {
    private static let service = "com.sebastian.crona"
    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
// Guardar aquí: serverURL y refreshToken. El accessToken vive solo en memoria (APIClient).
```

### 18.4 `Core/WebSocketClient.swift` (esquema ws/wss + reconexión)

```swift
import Foundation

final class WebSocketClient {
    private var task: URLSessionWebSocketTask?
    private var retry = 0
    var onEvent: ((WSEvent) -> Void)?

    func connect(baseURL: URL, token: String) {
        var c = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https") ? "wss" : "ws"          // HTTP soportado (SPEC §2)
        c.queryItems = [.init(name: "token", value: token)]
        task = URLSession.shared.webSocketTask(with: c.url!)
        task?.resume(); retry = 0; listen(baseURL: baseURL, token: token)
    }
    private func listen(baseURL: URL, token: String) {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, let data = s.data(using: .utf8),
                   let ev = try? APIClient.decoder.decode(WSEvent.self, from: data) { self.onEvent?(ev) }
                self.listen(baseURL: baseURL, token: token)
            case .failure:
                let delay = min(pow(2, Double(self.retry)), 30); self.retry += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Task { await self.reconnect(baseURL: baseURL) }   // re-lee token vigente del SessionStore
                }
            }
        }
    }
}
struct WSEvent: Decodable { let type: String; let payload: Data? /* decodificar según type */ }
```

(Nota de implementación: `payload` conviene decodificarlo con `JSONSerialization` → re-decode tipado según `type`; mantenerlo simple.)

### 18.5 `Core/Models.swift` — espejo exacto de §15

Enums (`String, Codable, CaseIterable`): `Role{ADMIN,USER}`, `InstanceStatus{CREATED,CONNECTING,CONNECTED,DISCONNECTED}`, `RecipientKind{CONTACT,GROUP}`, `MessageType{TEXT,IMAGE,VIDEO,DOCUMENT}`, `Recurrence{NONE,DAILY,WEEKLY,MONTHLY}`, `ScheduleStatus{ACTIVE,PAUSED,COMPLETED,CANCELLED,FAILED}`, `LogStatus{SENDING,SENT,DELIVERED,READ,FAILED}`.

Structs (`Identifiable, Codable, Hashable`): `User`, `AuthResponse`, `Instance`, `CreateInstanceResponse`, `QRResponse`, `SyncResult`, `Recipient`, `MediaUpload`, `ScheduledMessage`, `MessageLog`, `HistoryItem`, `MessageDetail`, `Paginated<T: Codable>` (`items`, `nextCursor`), `AdminSettings`. Campos y tipos **exactamente** como §15 (fechas = `Date`, opcionales donde §15 muestra `null`).

### 18.6 Tema y formato de fechas

```swift
enum Theme {
    static let accent = Color(red: 0.145, green: 0.827, blue: 0.400)   // #25D366
    static let avatarSize: CGFloat = 44          // 40 en el sidebar de macOS
}
```

`scheduleLabel(_ date: Date)` para la lista (locale `es`, zona del dispositivo): hoy → `"Hoy 5:00 PM"`; mañana → `"Mañana 9:00 AM"`; < 7 días → `"vie 5:00 PM"`; resto → `"20 jun 5:00 PM"`. Estados con SF Symbols según §9.3; recurrentes agregan `arrow.trianglehead.2.clockwise` (fallback `repeat`).

### 18.7 Textos de UI en español (usar literalmente)

| Contexto | Texto |
|---|---|
| Tabs | `Programados` · `Historial` · `Ajustes` |
| Botones | `Nuevo mensaje` · `Programar` · `Guardar cambios` · `Cancelar envío` · `Duplicar` · `Sincronizar contactos` · `Vincular número` · `Probar conexión` · `Reintentar` |
| Estados | `Programado` · `Enviando…` · `Enviado` · `Entregado` · `Leído` · `Fallido` · `Pausado` · `Cancelado` · `Completado` |
| Chips de hora | `En 1 hora` · `Esta noche 8:00 PM` · `Mañana 9:00 AM` · `Elegir fecha…` |
| Recurrencia | `No se repite` · `Todos los días` · `Semanal` · `Mensual` · `Hasta` |
| Vacíos | `No tienes mensajes programados.\nToca + para crear el primero.` · `Aún no hay envíos en el historial.` · `No hay contactos. Toca "Sincronizar contactos".` |
| Onboarding | `Dirección de tu servidor Crona` · `Conexión sin cifrar (http). Úsala solo si confías en la red o estás en una VPN.` |
| Banner desconexión | `Tu WhatsApp está desconectado — los envíos fallarán. Re-escanea el QR.` |
| QR | `Abre WhatsApp → Dispositivos vinculados → Vincular dispositivo y escanea este código.` |
| Confirmación | `Se enviará a {nombre} el {fecha} a las {hora}.` |

---

## 19. Runbook de puesta en marcha

### 19.1 VPS

```bash
# 1) Base de datos en el Postgres existente de Evolution
docker exec -it <contenedor_postgres> psql -U <usuario> -c "CREATE DATABASE crona;"

# 2) Nombre real de la red de Evolution → ponerlo en docker-compose.yml (networks.external)
docker network ls

# 3) Secretos
cp .env.example .env
openssl rand -hex 32   # → JWT_SECRET
openssl rand -hex 32   # → ENCRYPTION_KEY
openssl rand -hex 24   # → WEBHOOK_SECRET

# 4) Levantar (migraciones corren solas en el CMD del contenedor)
docker compose up -d --build && docker compose logs -f crona

# 5) Registrar al admin (primer usuario = ADMIN, sin invitación)
curl -s -X POST $URL/auth/register -H "Content-Type: application/json" \
  -d '{"email":"tu@correo.com","password":"…","name":"Sebastián"}'

# 6) Configurar Evolution y probar
curl -s -X PUT $URL/admin/settings -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"evolutionBaseUrl":"http://evolution-api:8080","evolutionGlobalApiKey":"LA_KEY_GLOBAL","ntfyBaseUrl":"https://ntfy.sh"}'
curl -s -X POST $URL/admin/settings/test -H "Authorization: Bearer $TOKEN"   # → {"ok":true,"version":"2.x.x"}
```

### 19.2 Mac + iPhone

```bash
brew install xcodegen
cd app && xcodegen generate && open Crona.xcodeproj
```

En Xcode: Signing & Capabilities → Team = tu **Personal Team** → Run en "My Mac" y luego en el iPhone conectado. En el iPhone: Ajustes → General → VPN y gestión de dispositivos → confiar en tu Apple ID. ⚠️ El perfil gratuito expira a los **7 días**: repetir Run desde Xcode (los envíos NO se detienen mientras tanto).

### 19.3 ntfy

Instalar **ntfy** desde el App Store → suscribirse al topic que muestra Crona en Ajustes (se genera aleatorio: `crona-{nombre}-{6 chars}`). Si el servidor ntfy es self-hosted, su `server.yml` necesita `upstream-base-url: "https://ntfy.sh"` para que el push llegue a iOS vía APNs.

---

## 20. `CLAUDE.md` (copiar este bloque tal cual a la raíz del repo)

```markdown
# CLAUDE.md — Reglas de trabajo para Crona

- Lee SPEC.md COMPLETO antes de tocar código. Las decisiones de SPEC §2 son finales: no propongas alternativas.
- Trabaja FASE POR FASE (SPEC §11). No avances de fase sin cumplir su criterio ✔; pega la evidencia (output de curl o captura) en DECISIONS.md.
- Los apéndices SPEC §15–§19 son normativos: contrato JSON exacto, implementaciones de referencia tal cual, runbook reflejado en README.md.
- Si encuentras una ambigüedad real, elige la opción más simple y anótala en DECISIONS.md. No preguntes.

## Comandos
- Backend dev:      cd server && npm run dev
- Migraciones:      cd server && npx prisma migrate dev --name <nombre>
- Build backend:    cd server && npm run build
- Proyecto Xcode:   cd app && xcodegen generate

## Estilo
- Server: TypeScript strict, ESM, sin `any` (salvo payloads crudos de Evolution), zod en todos los bodies.
- App: Swift 5.9+, SwiftUI + Observation (@Observable), async/await, SIN dependencias externas.
- Código e identificadores en inglés; textos de UI en español (SPEC §18.7).
- Commits: `feat(fase-N): descripción` / `fix(fase-N): …`. Un commit como mínimo por fase.

## Prohibiciones duras
- NUNCA agregar capabilities/entitlements de iOS (firma con Personal Team gratuito — el build fallaría).
- NUNCA exponer las apikeys de Evolution en respuestas de la API ni en las apps.
- NUNCA usar los formatos de body de Evolution v1 (textMessage/mediaMessage anidados): esto es v2.
- NUNCA enviar base64 con prefijo `data:` a Evolution.
```

**Prompt inicial sugerido para Claude Code:**

```
Lee SPEC.md y CLAUDE.md completos. Implementa la Fase 0 (SPEC §11) y detente:
muéstrame el output de `curl localhost:3000/health` antes de continuar con la Fase 1.
```
