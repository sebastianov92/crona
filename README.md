# Crona

Programa mensajes de WhatsApp (texto, fotos, videos y PDF) para que se envíen solos en la fecha y hora que elijas, y automatiza respuestas a los mensajes que recibes — usando tu propio número, en tu propio servidor.

- **Crona Server** (Node 20 + Fastify + Prisma + PostgreSQL): única fuente de verdad. Guarda los mensajes, ejecuta el scheduler, recibe webhooks de Evolution y notifica por ntfy. Los mensajes se envían aunque ninguna app esté abierta.
- **Crona para iOS y macOS** (SwiftUI multiplataforma): clientes delgados. Mac ↔ iPhone se sincronizan solos porque ambos hablan con el mismo servidor (REST + WebSocket).
- **Evolution API v2**: ya instalada en tu VPS; no se modifica.

## Features

- 📅 **Mensajes programados** — texto, foto, video o PDF a contactos y grupos, con fecha y hora exacta
- 🔁 **Recurrentes** — diario, semanal (por días), mensual y anual (cumpleaños), con fecha límite opcional
- 🎲 **Anti-detección** — variación aleatoria opcional de ±1–5 min en recurrentes y "escribiendo…" simulado
- 👥 **Múltiples destinatarios** — un mensaje a varios contactos/grupos, con la variable `{nombre}` personalizada por destinatario
- 🤖 **Respuestas automáticas** — por palabra clave, por contacto específico o cualquier mensaje; con horario, días de la semana y respuesta con retraso aleatorio de 1–5 min
- 🔔 **Notificación por ntfy** — push al iPhone si un envío falla, si WhatsApp se desconecta, o cuando te escribe alguien que marcaste
- ✓✓ **Historial** — enviado → entregado → leído, con reintentos automáticos ante fallos
- ⏸️ **Pausar todo** — modo vacaciones con un botón
- 📱 **Widget** iOS/macOS con los próximos envíos
- 🔐 **Multiusuario** — registro por invitación; cada usuario vincula su propio número y solo ve lo suyo
- 🔢 **Multi-instancia** — varios números de WhatsApp por usuario, reglas y mensajes por número

## Instalación del servidor

### Instalación Completa (no tienes Evolution — trae todo)

Levanta Postgres + Evolution API v2 + Crona, ya conectados entre sí. Es el [`docker-compose.yml`](docker-compose.yml) de la raíz — compatible con paneles tipo Hostinger (pega la URL del repo y define las variables):

```bash
git clone https://github.com/sebastianov92/crona.git && cd crona
cp .env.full.example .env && nano .env   # genera los secretos (openssl rand -hex 32)
docker compose up -d
```

Variables requeridas:

| Variable | Nota |
|---|---|
| `POSTGRES_PASSWORD` | aleatoria |
| `EVOLUTION_API_KEY` | aleatoria |
| `JWT_SECRET` | mínimo 32 caracteres |
| `ENCRYPTION_KEY` | **exactamente 64 caracteres hex** |
| `WEBHOOK_SECRET` | mínimo 16 caracteres |
| `PUBLIC_URL` | `http://IP_DEL_VPS:3000` |

Evolution queda preconfigurada automáticamente. Desde la app: servidor `http://IP_DEL_VPS:3000` → crear cuenta (el primero es ADMIN) → vincular tu número.

Actualizar: `git pull && docker compose pull && docker compose up -d`

### Instalación sin Evolution (ya la tienes corriendo)

Usa [`docker-compose.evolution-existente.yml`](docker-compose.evolution-existente.yml) — solo Crona, enganchado a tu red de Docker existente:

```bash
git clone https://github.com/sebastianov92/crona.git && cd crona

# 1. Base de datos en tu Postgres de Evolution
docker exec -it <contenedor_postgres> psql -U <usuario> -c "CREATE DATABASE crona;"

# 2. Red de Evolution → ponla en networks.evolution-net.name del yml
docker network ls

# 3. Secretos
cp .env.example .env && nano .env   # DATABASE_URL a tu Postgres + secretos con openssl rand

# 4. Levantar
docker compose -f docker-compose.evolution-existente.yml up -d
```

Luego configura Evolution desde la app (Ajustes → Servidor Evolution → URL interna + key global → Probar conexión).

> 💡 En ambos casos el server queda por HTTP en el puerto 3000. Para TLS: dominio + el servicio `caddy` incluido en el compose de Evolution-existente, o Cloudflare Tunnel, o Tailscale.

## Apps iOS y macOS

Descarga la última versión desde [**Releases**](https://github.com/sebastianov92/crona/releases):

- **Mac (`Crona.dmg`)** — abre el DMG, arrastra Crona a Aplicaciones. La primera vez: click derecho → **Abrir** (la app no está notarizada).
- **iPhone (`Crona.ipa`)** — el IPA viene sin firmar; instálalo con [Sideloadly](https://sideloadly.io) o [AltStore](https://altstore.io) usando tu propio Apple ID. Con Apple ID gratuito la firma dura 7 días (re-instala con la misma herramienta para renovar).

## Notificaciones push (ntfy)

1. Instala **ntfy** desde el App Store en el iPhone.
2. En Crona → Ajustes → Notificaciones: genera tu topic y guárdalo.
3. En la app ntfy: suscríbete a ese topic.

Recibirás push cuando un mensaje **falle**, cuando WhatsApp **se desconecte**, y por las reglas de "Avisarme" que configures. El topic funciona como secreto — no lo compartas.

**ntfy self-hosted**: su `server.yml` necesita `upstream-base-url: "https://ntfy.sh"` para que el push llegue a iOS vía APNs.

## Invitar a más usuarios

El registro está cerrado por invitación: en la app (rol ADMIN) → Ajustes → Usuarios e invitaciones → **Crear código de invitación** (expira en 7 días). Cada usuario vincula **su propio** número y solo ve sus mensajes y reglas.
