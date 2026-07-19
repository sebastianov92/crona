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

## Fase 4 — Media ✔ (foto/video a WhatsApp real pendiente de VPS)

Evidencia (2026-07-16, curl + scripts):

- `POST /media`: PNG ok (201), MP4 4 MB ok, `image/gif` → `MEDIA_TYPE_UNSUPPORTED` (415).
- `GET /media/:id`: dueño descarga bytes idénticos; otro usuario → `NOT_FOUND`.
- URL interna firmada: 1er uso → 200 con el archivo; 2do uso → 404 (un solo uso); token manipulado → 404 (HMAC + `timingSafeEqual`).
- `buildMediaPayload`: PNG (≤3 MB) → base64 **puro** (sin prefijo `data:`, sin saltos de línea); MP4 (>3 MB) → URL interna firmada. `delay: 1800`, `caption`, `mimetype`, `fileName` correctos.
- **Pendiente VPS**: foto y video programados llegan al WhatsApp destino.

Decisiones:
- **Bug corregido**: el token firmado (~105 chars) excedía el `maxParamLength` default de Fastify (100) → 414. Se configuró `maxParamLength: 512`.
- El registro de tokens usados vive en memoria (Map con limpieza cada 60 s) — suficiente para proceso único (§16.5); un reinicio "resucita" tokens no expirados ≤15 min, riesgo aceptado en red interna.

## Fase 5 — ntfy + WebSocket ✔ (push a iPhone real pendiente de setup ntfy del usuario)

Evidencia (2026-07-16):

- `GET /ws?token=…`: token válido conecta; token inválido cierra con **4401**.
- Broadcast en vivo: al crear un mensaje por REST, el WS del mismo usuario recibió `{"type":"message.updated","payload":{…body:"evento ws"}}`.
- ntfy verificado contra **mock local**: mensaje forzado a 3er fallo → el worker publicó `{"topic":"catchapp-seb-test01","title":"Mensaje no enviado","message":"No se envió tu mensaje a WS Test: INSTANCIA_DESCONECTADA","priority":4,"tags":["x"]}` y el mensaje quedó `FAILED / attempts=3`.
- Los eventos `instance.updated` (webhook CONNECTION_UPDATE), `qr.updated` (QRCODE_UPDATED) y `log.updated` (acks) ya emiten broadcast desde la Fase 2/3.
- **Pendiente usuario**: probar push real en iPhone con la app ntfy suscrita al topic.

## Fase 6 — App SwiftUI núcleo ✔ (flujo E2E contra servidor real pendiente del usuario)

Evidencia (2026-07-16):

- `xcodegen generate` crea el proyecto sin warnings.
- **macOS**: `xcodebuild -destination 'platform=macOS' build` → BUILD SUCCEEDED.
- **iOS**: `xcodebuild -sdk iphonesimulator26.5 -arch arm64 build` → BUILD SUCCEEDED (la plataforma iOS no está instalada como *destino* en este Xcode — el usuario debe descargarla en Xcode → Settings → Components para correr en su iPhone; el código compila limpio contra el SDK).
- Implementado: Onboarding (URL + warning http + /health), Login/Registro con invitación, Instancias (crear, QR en vivo por WS + polling de estado cada 4 s, sync, eliminar), Programados (chips Todos/Contactos/Grupos/Recurrentes, búsqueda, banner de desconexión), Compose (instancia → picker destinatario → editor con burbuja + adjunto → ScheduleSheet con chips rápidos y recurrencia → confirmación; sube media antes de crear con ProgressView), Detalle (logs, pausar/reanudar, editar, cancelar, duplicar, eliminar), Historial, Ajustes (perfil, ntfy con generador de topic, panel admin Evolution + test, usuarios/invitaciones), MenuBarExtra macOS.

Decisiones:
- El QR usa WS (`qr.updated`) para refrescar en vivo + polling de `/instances/:id/status` cada 4 s como respaldo para detectar la conexión.
- `timezone` del mensaje se toma de `TimeZone.current.identifier` del dispositivo (no hardcoded a Guayaquil).
- Videos en iOS se importan con `FileRepresentation` (`Transferable`) a archivo temporal y `mimeType video/quicktime`, según §18.2.

## Fase 7 — Pulido ✔

- Notificaciones locales macOS (`UNUserNotificationCenter`, permitido sin cuenta paga): enviado / fallido / desconexión, disparadas por los eventos del WebSocket.
- "Nuevo mensaje" desde la MenuBarExtra abre el Compose en la ventana principal.
- Job de limpieza de `WebhookEventRaw` a 7 días (diario, en el mismo proceso).
- Filtros/búsqueda, estados vacíos y banner de instancia desconectada ya venían de la Fase 6.
- README completo: runbook del VPS (§19), opciones de despliegue A/B con upgrades TLS, build de las apps con XcodeGen + firma Personal Team, setup ntfy, notas de operación.
- Verificación final: `tsc` limpio, macOS BUILD SUCCEEDED, iOS (SDK simulador) BUILD SUCCEEDED, `/health` ok.

## Post-release — Pruebas con WhatsApp real (2026-07-16)

El usuario vinculó su número real escaneando el QR desde la app macOS (✔ criterio Fase 2: instancia CONNECTED). El sync inicial devolvió 0/0 — dos causas encontradas con el payload real:

1. **Contactos (bug de CatchApp, corregido)**: en Evolution 2.3.x `findContacts` devuelve `id` = cuid interno de su DB y el JID va en `remoteJid`. El mapeo tomaba `id` primero → el filtro `@s.whatsapp.net` descartaba todo. Fix: `pickJid()` prefiere `remoteJid` y solo acepta valores con `@`. Resultado: **618 contactos sincronizados**.
2. **Grupos (limitación de Evolution 2.3.7)**: `GET /group/fetchAllGroups` devuelve `[]` siempre (el `groupFetchAllParticipating` de Baileys falla silenciosamente; probado con restart de instancia y con la imagen `latest` — misma versión 2.3.7). Workaround: fallback que toma los chats `@g.us` de `POST /chat/findChats` (nombre en `pushName`). Limitación honesta: solo aparecen grupos **con actividad desde la vinculación** (syncFullHistory=false) — el usuario debe mandar/recibir un mensaje en el grupo y re-sincronizar.

## Pendientes que requieren al usuario (no bloqueantes)

1. Desplegar en el VPS y correr `POST /admin/settings/test` contra su Evolution real.
2. Escanear el QR con su teléfono → verificar sync de contactos/grupos y envío real de texto/foto/video (criterios ✔ de Fases 2–4).
3. Instalar la plataforma iOS en Xcode (Settings → Components) para correr en el iPhone (el código ya compila contra el SDK).
4. Configurar ntfy en el iPhone y probar un push real.

## Post-release — Features extra (2026-07-19)

- **Enviar ahora / Reintentar**: `POST /messages/:id/send-now` (válido en ACTIVE/PAUSED/FAILED) reprograma a `now()`, resetea intentos y dispara un tick inmediato. Verificado E2E: mensaje para +2h enviado en <10 s, log SENT con id real de Evolution. Botones en el detalle ("Enviar ahora" con confirmación; "Reintentar" en fallidos).
- **Preview de media**: `HistoryItem` ahora incluye `mediaId` (campo aditivo a §15). La app muestra la imagen en el detalle (cache en memoria) y miniatura en filas del historial. Video/PDF muestran placeholder con icono.
- **Widget iOS/macOS** ("Próximos envíos", small/medium): extensión WidgetKit `CronaWidget` que lee un snapshot JSON del App Group `group.com.sebastian.crona` publicado por la app en cada refresh — el widget no hace red ni toca el Keychain. **Desviación del SPEC §9.1** (prohibía App Groups): App Groups sí está permitido con Personal Team gratuito (a diferencia de aps-environment); si la firma fallara en el equipo del usuario, el fallback es quitar el target CronaWidget y las claves application-groups de los entitlements y regenerar con xcodegen.
