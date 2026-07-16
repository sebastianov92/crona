import { prisma } from "../db.js";
import { decrypt, encrypt } from "./crypto.js";
import { errors } from "../lib/errors.js";

export interface Settings {
  evolutionBaseUrl: string;
  evolutionGlobalApiKey: string;
  ntfyBaseUrl: string;
}

let cache: Settings | null = null;

export async function getSettings(): Promise<Settings> {
  if (cache) return cache;
  const row = await prisma.serverSettings.findUnique({ where: { id: 1 } });
  if (!row) throw errors.evolutionUnreachable("Evolution API no está configurada todavía (panel admin)");
  cache = {
    evolutionBaseUrl: row.evolutionBaseUrl,
    evolutionGlobalApiKey: decrypt(row.evolutionGlobalApiKeyEnc),
    ntfyBaseUrl: row.ntfyBaseUrl,
  };
  return cache;
}

export async function updateSettings(input: {
  evolutionBaseUrl: string;
  evolutionGlobalApiKey?: string;
  ntfyBaseUrl: string;
}): Promise<void> {
  const existing = await prisma.serverSettings.findUnique({ where: { id: 1 } });
  const keyEnc = input.evolutionGlobalApiKey
    ? encrypt(input.evolutionGlobalApiKey)
    : existing?.evolutionGlobalApiKeyEnc;
  if (!keyEnc) throw errors.validation("Falta la API key global de Evolution.");
  await prisma.serverSettings.upsert({
    where: { id: 1 },
    create: {
      id: 1,
      evolutionBaseUrl: input.evolutionBaseUrl,
      evolutionGlobalApiKeyEnc: keyEnc,
      ntfyBaseUrl: input.ntfyBaseUrl,
    },
    update: {
      evolutionBaseUrl: input.evolutionBaseUrl,
      evolutionGlobalApiKeyEnc: keyEnc,
      ntfyBaseUrl: input.ntfyBaseUrl,
    },
  });
  cache = null;
}

export async function settingsSummary() {
  const row = await prisma.serverSettings.findUnique({ where: { id: 1 } });
  return {
    evolutionBaseUrl: row?.evolutionBaseUrl ?? "",
    evolutionGlobalApiKeySet: Boolean(row?.evolutionGlobalApiKeyEnc),
    ntfyBaseUrl: row?.ntfyBaseUrl ?? "https://ntfy.sh",
  };
}
