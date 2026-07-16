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
