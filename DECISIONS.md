# DECISIONS.md — Decisiones tomadas durante implementación

## 2026-07-16 — Setup inicial

- **Entorno de desarrollo local**: se usa un contenedor Postgres 16 local (`docker run … postgres:16`) para migraciones y pruebas con `curl`. En producción se usa el Postgres de Evolution con la base `catchapp` (SPEC §2).
- **Pruebas contra Evolution real**: la Evolution API vive en el VPS del usuario y no es accesible desde la máquina de desarrollo. Los criterios ✔ que requieren Evolution/WhatsApp real (Fases 1–5) se verifican localmente hasta donde es posible (rutas, validaciones, flujo del worker) y quedan marcados como **pendiente de verificación en VPS** con el comando `curl` exacto a ejecutar allí.

## Fase 0 — Scaffold ✔

Evidencia (2026-07-16):

```
$ curl -s localhost:3000/health
{"ok":true,"service":"catchapp","ts":"2026-07-16T16:41:48.474Z"}
```

- Migración inicial `20260716164116_init` aplicada contra Postgres 16 local (contenedor `catchapp-dev-pg`, puerto 5433).
- `npm run build` (tsc strict) pasa limpio.

## Fase 1 — Auth + Admin ✔ (parcial: test Evolution pendiente de VPS)

Evidencia (2026-07-16, curl contra server local):

- `POST /auth/register` sin usuarios previos → crea ADMIN y devuelve `{accessToken, refreshToken, user}` (201).
- `POST /auth/refresh` rota el token; reusar el refresh viejo → `TOKEN_EXPIRED`.
- Registro sin invitación con usuarios existentes → `INVITE_REQUIRED`; con código de `POST /admin/invites` (expira 7 días) → crea USER.
- `PUT /admin/settings` guarda la key cifrada (AES-256-GCM); `GET /admin/settings` devuelve `evolutionGlobalApiKeySet: true`, nunca la key en claro.
- `GET /admin/users` como USER → `FORBIDDEN`.
- `POST /admin/settings/test` sin Evolution accesible → `EVOLUTION_UNREACHABLE` (formato de error correcto). **Pendiente VPS**: `curl -s -X POST $URL/admin/settings/test -H "Authorization: Bearer $TOKEN"` debe devolver `{"ok":true,"version":"2.x.x"}`.

Decisiones:
- Se añadió el código de error `INTERNAL_ERROR` (500 genérico) al catálogo de §15 — la lista del SPEC no cubría errores internos.
- `POST /auth/logout` recibe `{ refreshToken }` en el body y lo revoca (idempotente); no requiere access token (el refresh es la credencial).

**Actualización**: se levantó una **Evolution API v2.3.7 real** en local (contenedor `evolution-dev`, puerto 8081) → `POST /admin/settings/test` devuelve `{"ok":true,"version":"2.3.7"}`. ✔ criterio de Fase 1 cumplido contra Evolution real.

## Fase 2 — Instancias ✔ (vinculación con teléfono real pendiente del usuario)

Evidencia (2026-07-16, contra Evolution v2.3.7 real en local):

- `POST /instances {"name":"Personal"}` → crea `u2rce-personal` en Evolution con webhook interno configurado; devuelve `qrBase64` (PNG data-URI de 13 KB, QR real de WhatsApp).
- `GET /instances/:id/qr` → re-solicita QR vía `/instance/connect` (base64 + code manejados).
- `GET /instances/:id/status` → consulta `connectionState` en vivo → `CONNECTING` y sincroniza el campo local.
- Webhooks reales recibidos y guardados en `WebhookEventRaw`: `qrcode.updated` y `connection.update` (Evolution → `http://host.docker.internal:3000/webhooks/evolution/{secret}`).
- Aislamiento multiusuario: user2 pidiendo la instancia de admin → `NOT_FOUND`.
- `POST /instances/:id/sync` sin WhatsApp vinculado → error controlado `EVOLUTION_UNREACHABLE` (timeout de findContacts en instancia no conectada). **Pendiente usuario**: escanear QR con teléfono real y verificar que `/instances/:id/recipients` lista contactos y grupos.

Decisiones:
- La respuesta de `/instance/create` varía entre 2.x: `hash` puede ser string u objeto `{apikey}` — se manejan ambos.
- `res.code` de `/instance/connect` es el string crudo del QR (`2@…`), NO un pairing code; `pairingCode` solo se toma de `qrcode.pairingCode`/`pairingCode`.
- Errores de Evolution (`EvolutionError`) se mapean a 502 `EVOLUTION_UNREACHABLE` en el error handler global.
- En dev local, `INTERNAL_URL=http://host.docker.internal:3000` para que el contenedor de Evolution alcance CatchApp; en VPS es `http://catchapp:3000` (red Docker compartida).

## Fase 3 — Mensajes de texto programados ✔ (entrega real a WhatsApp pendiente de VPS)

Evidencia (2026-07-16, curl + Postgres local):

- CRUD completo verificado: crear (+90 s), listar `upcoming`, `PATCH` (body + pausa), `duplicate` (copia PAUSED), `cancel`, `DELETE` (solo terminales), y `PATCH` sobre inexistente → `NOT_FOUND`.
- Validaciones: fecha pasada, media sin `mediaId`, `WEEKLY` sin días → `VALIDATION_ERROR` con mensajes en español.
- Worker verificado: mensaje forzado a `nextRunAt=now()` → en el siguiente tick fue reclamado (`FOR UPDATE SKIP LOCKED` + `claimedAt`), la instancia estaba desconectada → `attempts=1`, `lastError=INSTANCIA_DESCONECTADA`, `nextRunAt=+2 min` (backoff), claim liberado.
- Recurrencia (Luxon, zona del mensaje): DAILY conserva la hora local; WEEKLY `[1,5]` desde jueves → viernes; MONTHLY 31 ene → 28 feb (clamp). Script de verificación ejecutado.
- **Pendiente VPS**: texto programado a +2 min llega al WhatsApp destino y su log pasa a DELIVERED (requiere instancia vinculada).

Decisiones:
- Cuando la instancia está desconectada NO se crea `MessageLog` por intento (no hubo envío real, fiel al pseudocódigo de §7); el detalle queda en `lastError` y el fallo definitivo notifica por ntfy.
- `duplicate` crea la copia en `PAUSED` (lista para editar sin que el worker la tome); si la fecha original ya pasó, propone `now()+1h`.
- Tras reintentos con backoff, la siguiente ocurrencia recurrente se calcula desde el último `nextRunAt` (implementación normativa §17.5 tal cual) — puede desplazar la hora hasta +12 min tras una ocurrencia con 2 reintentos.
- `PATCH` con `scheduledAt` nuevo resetea `nextRunAt`, `attempts` y `lastError`.
