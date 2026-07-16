import { getSettings } from "./settings.js";

interface NtfyUser {
  ntfyTopic: string | null;
  ntfyToken: string | null;
}

interface Notification {
  title: string;
  message: string;
  priority?: number;
  tags?: string[];
}

// Publicar en modo JSON (soporta tildes y emojis en el título).
// Prioridades: fallo de mensaje / instancia desconectada → 4 (high); enviado OK → 3 (default)
export async function ntfyPublish(user: NtfyUser, n: Notification): Promise<void> {
  if (!user.ntfyTopic) return;
  try {
    const s = await getSettings();
    await fetch(s.ntfyBaseUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(user.ntfyToken ? { authorization: `Bearer ${user.ntfyToken}` } : {}),
      },
      body: JSON.stringify({
        topic: user.ntfyTopic,
        title: n.title,
        message: n.message,
        priority: n.priority ?? 3,
        tags: n.tags ?? [],
      }),
    });
  } catch (err) {
    // ntfy NUNCA rompe un envío
    console.warn("ntfy publish failed", err);
  }
}
