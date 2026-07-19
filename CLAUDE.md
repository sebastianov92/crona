# CLAUDE.md — Reglas de trabajo para Crona

- Lee SPEC.md COMPLETO antes de tocar código. Las decisiones de SPEC §2 son finales: no propongas alternativas.
- Trabaja FASE POR FASE (SPEC §11). No avances de fase sin cumplir su criterio ✔; pega la evidencia (output de curl o captura) en DECISIONS.md.
- Los apéndices SPEC §15–§19 son normativos: contrato JSON exacto, implementaciones de referencia tal cual, runbook reflejado en README.md.
- Si encuentras una ambigüedad real, elige la opción más simple y anótala en DECISIONS.md. No preguntes.

## Comandos
- Backend dev:      cd server && npm run dev
- Migraciones:      cd server && npx prisma migrate dev --name <nombre>
- Build backend:    cd server && npm run build
- Proyecto Xcode:   cd apps/Crona && xcodegen generate

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
