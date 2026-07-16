import { getSettings } from "./settings.js";
import { errors } from "../lib/errors.js";

export class EvolutionError extends Error {
  constructor(
    public status: number,
    public body: unknown,
  ) {
    super(`Evolution API respondió ${status}: ${JSON.stringify(body)?.slice(0, 500)}`);
  }
}

async function evoFetch(
  path: string,
  opts: { method?: string; body?: unknown; apikey: string; timeoutMs?: number },
): Promise<any> {
  const s = await getSettings(); // ServerSettings desde DB (key desencriptada)
  let res: Response;
  try {
    res = await fetch(new URL(path, s.evolutionBaseUrl), {
      method: opts.method ?? "GET",
      headers: { apikey: opts.apikey, "content-type": "application/json" },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      signal: AbortSignal.timeout(opts.timeoutMs ?? 30_000),
    });
  } catch (e) {
    throw errors.evolutionUnreachable(e instanceof Error ? e.message : String(e));
  }
  const json: any = await res.json().catch(() => null);
  if (!res.ok) {
    if (json?.key?.id ?? json?.response?.key?.id) return json; // Gotcha 7: 400 pero el mensaje salió
    throw new EvolutionError(res.status, json);
  }
  return json;
}

async function GLOBAL(): Promise<string> {
  return (await getSettings()).evolutionGlobalApiKey;
}

// connectionState se cachea 60 s por instancia
const stateCache = new Map<string, { state: string; at: number }>();

export const evolution = {
  version: async () => evoFetch("/", { apikey: await GLOBAL() }),
  createInstance: async (body: unknown) =>
    evoFetch("/instance/create", { method: "POST", body, apikey: await GLOBAL() }),
  connect: async (n: string) => evoFetch(`/instance/connect/${n}`, { apikey: await GLOBAL() }),
  state: async (n: string) => evoFetch(`/instance/connectionState/${n}`, { apikey: await GLOBAL() }),
  logout: async (n: string) => evoFetch(`/instance/logout/${n}`, { method: "DELETE", apikey: await GLOBAL() }),
  remove: async (n: string) => evoFetch(`/instance/delete/${n}`, { method: "DELETE", apikey: await GLOBAL() }),
  sendText: (n: string, k: string, body: unknown) =>
    evoFetch(`/message/sendText/${n}`, { method: "POST", body, apikey: k }),
  sendMedia: (n: string, k: string, body: unknown) =>
    evoFetch(`/message/sendMedia/${n}`, { method: "POST", body, apikey: k, timeoutMs: 180_000 }),
  findContacts: (n: string, k: string) =>
    evoFetch(`/chat/findContacts/${n}`, { method: "POST", body: { where: {} }, apikey: k }),
  findChats: (n: string, k: string) =>
    evoFetch(`/chat/findChats/${n}`, { method: "POST", body: { where: {} }, apikey: k }),
  fetchAllGroups: (n: string, k: string) =>
    evoFetch(`/group/fetchAllGroups/${n}?getParticipants=false`, { apikey: k }),

  /** Estado de conexión ("open" | "connecting" | "close"), con cache de 60 s. */
  async cachedState(instanceName: string): Promise<string> {
    const hit = stateCache.get(instanceName);
    if (hit && Date.now() - hit.at < 60_000) return hit.state;
    const res = await evolution.state(instanceName);
    const state: string = res?.instance?.state ?? "close";
    stateCache.set(instanceName, { state, at: Date.now() });
    return state;
  },

  invalidateStateCache(instanceName: string) {
    stateCache.delete(instanceName);
  },
};
