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
