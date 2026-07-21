// Cliente API — mismo origen (la web la sirve el propio servidor Crona).
// accessToken en memoria; refreshToken en localStorage con rotación single-flight.

let accessToken: string | null = null;
let refreshing: Promise<void> | null = null;

export class ApiError extends Error {
  constructor(
    public code: string,
    message: string,
  ) {
    super(message);
  }
}

function getRefreshToken(): string | null {
  return localStorage.getItem("refreshToken");
}

async function refreshSession(): Promise<void> {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    const rt = getRefreshToken();
    if (!rt) throw new ApiError("TOKEN_EXPIRED", "Sesión expirada.");
    const res = await fetch("/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: rt }),
    });
    if (!res.ok) {
      localStorage.removeItem("refreshToken");
      throw new ApiError("TOKEN_EXPIRED", "Sesión expirada.");
    }
    const data = await res.json();
    accessToken = data.accessToken;
    localStorage.setItem("refreshToken", data.refreshToken);
  })().finally(() => {
    refreshing = null;
  });
  return refreshing;
}

export async function api<T>(
  method: string,
  path: string,
  body?: unknown,
  retry = true,
): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: {
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 && retry) {
    await refreshSession();
    return api(method, path, body, false);
  }
  if (!res.ok) {
    const data = await res.json().catch(() => null);
    if (data?.error) throw new ApiError(data.error.code, data.error.message);
    throw new ApiError("HTTP", `Error de red (HTTP ${res.status}).`);
  }
  return res.json();
}

export const session = {
  setTokens(access: string, refresh: string) {
    accessToken = access;
    localStorage.setItem("refreshToken", refresh);
  },
  hasRefresh(): boolean {
    return !!getRefreshToken();
  },
  async tryRestore(): Promise<boolean> {
    if (!getRefreshToken()) return false;
    try {
      await refreshSession();
      return true;
    } catch {
      return false;
    }
  },
  async logout() {
    const rt = getRefreshToken();
    if (rt) await api("POST", "/auth/logout", { refreshToken: rt }).catch(() => {});
    localStorage.removeItem("refreshToken");
    accessToken = null;
  },
  token(): string | null {
    return accessToken;
  },
};

/**
 * Trae TODAS las páginas de un endpoint paginado (la agenda puede tener cientos de contactos
 * y el picker debe mostrarlos completos, no solo la primera página).
 */
export async function fetchAll<T>(path: string, params: Record<string, string> = {}, maxPages = 20): Promise<T[]> {
  const out: T[] = [];
  let cursor: string | null = null;
  for (let i = 0; i < maxPages; i++) {
    const q = new URLSearchParams({ ...params, limit: "200", ...(cursor ? { cursor } : {}) });
    const page: { items: T[]; nextCursor: string | null } = await api(`GET`, `${path}?${q}`);
    out.push(...page.items);
    cursor = page.nextCursor;
    if (!cursor) break;
  }
  return out;
}

export async function uploadMedia(file: File): Promise<{ mediaId: string }> {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch("/media", {
    method: "POST",
    headers: accessToken ? { authorization: `Bearer ${accessToken}` } : {},
    body: form,
  });
  if (res.status === 401) {
    await refreshSession();
    return uploadMedia(file);
  }
  if (!res.ok) {
    const data = await res.json().catch(() => null);
    throw new ApiError(data?.error?.code ?? "HTTP", data?.error?.message ?? `HTTP ${res.status}`);
  }
  return res.json();
}

const mediaCache = new Map<string, string>();

export async function mediaBlobURL(mediaId: string): Promise<string | null> {
  const hit = mediaCache.get(mediaId);
  if (hit) return hit;
  try {
    const res = await fetch(`/media/${mediaId}`, {
      headers: accessToken ? { authorization: `Bearer ${accessToken}` } : {},
    });
    if (!res.ok) return null;
    const url = URL.createObjectURL(await res.blob());
    mediaCache.set(mediaId, url);
    return url;
  } catch {
    return null;
  }
}

export function connectWS(onEvent: (type: string, payload: unknown) => void): () => void {
  let ws: WebSocket | null = null;
  let closed = false;
  let retry = 0;

  const open = () => {
    if (closed || !accessToken) return;
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/ws?token=${accessToken}`);
    ws.onmessage = (e) => {
      try {
        const msg = JSON.parse(e.data);
        onEvent(msg.type, msg.payload);
      } catch {
        /* ignorar */
      }
    };
    ws.onopen = () => {
      retry = 0;
    };
    ws.onclose = () => {
      if (closed) return;
      const delay = Math.min(2 ** retry, 30) * 1000;
      retry += 1;
      setTimeout(open, delay);
    };
  };
  open();
  return () => {
    closed = true;
    ws?.close();
  };
}
