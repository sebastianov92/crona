import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError, uploadMedia } from "../api";
import { useApp } from "../App";
import { Avatar, messagePreview, scheduleLabel, useAsync } from "../lib";
import { quickDate } from "../types";
import type { ChatBubble, ChatSummary, Paginated } from "../types";
import { IconCheck, IconChevron, IconPaperclip, IconSend, IconTrash } from "../icons";
import { clampTyping, QUICK_PERIODS, quickActive, VoiceRecorderButton } from "./Scheduled";
import { GroupsButton } from "./Groups";

function timeLabel(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString("es", { hour: "numeric", minute: "2-digit" });
  return d.toLocaleDateString("es", { day: "numeric", month: "short" }) + " " + d.toLocaleTimeString("es", { hour: "numeric", minute: "2-digit" });
}

export default function Chats() {
  const { toast } = useApp();
  const [open, setOpen] = useState<ChatSummary | null>(null);
  const [chats, loading, reload] = useAsync(
    async () => (await api<Paginated<ChatSummary>>("GET", "/chats")).items,
    [],
  );

  const removeChat = async (c: ChatSummary) => {
    if (!confirm(`¿Quitar el chat con ${c.name}? Volverá a aparecer cuando haya un mensaje nuevo.`)) return;
    try {
      const q = new URLSearchParams({ instanceId: c.instanceId, jid: c.jid });
      await api("DELETE", `/chats?${q}`);
      reload();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al quitar el chat");
    }
  };

  useEffect(() => {
    const fn = () => reload();
    window.addEventListener("chat-incoming", fn);
    return () => window.removeEventListener("chat-incoming", fn);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (open) return <ChatView chat={open} onBack={() => { setOpen(null); reload(); }} />;

  return (
    <div className="page">
      <div className="labelrow" style={{ marginBottom: 14 }}>
        <h1 className="pagetitle" style={{ margin: 0 }}>Chats</h1>
        <GroupsButton />
      </div>
      <div className="card">
        {!loading && (chats ?? []).length === 0 && (
          <div className="empty">
            Aquí aparecen las personas a las que ya programaste mensajes.
            <br />
            Programa tu primer mensaje desde la pestaña Programados.
          </div>
        )}
        {(chats ?? []).map((c) => (
          <button key={`${c.instanceId}|${c.jid}`} className="row" onClick={() => setOpen(c)}>
            <Avatar name={c.name} url={c.pictureUrl} />
            <div className="main">
              <div className="name">{c.name}</div>
              <div className="sub">
                {c.last ? `${c.last.fromMe ? "Tú: " : ""}${messagePreview(c.last.type, c.last.body)}` : "Sin mensajes todavía"}
              </div>
            </div>
            <div className="right">
              <div className="time">{timeLabel(c.lastAt)}</div>
              {c.pendingCount > 0 && <div className="state">{c.pendingCount} pendiente{c.pendingCount > 1 ? "s" : ""}</div>}
            </div>
            <span
              title="Quitar chat"
              style={{ color: "var(--text2)", display: "flex", padding: 6 }}
              onClick={(e) => {
                e.stopPropagation();
                removeChat(c);
              }}
            >
              <IconTrash size={15} />
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}

function ChatView({ chat, onBack }: { chat: ChatSummary; onBack: () => void }) {
  const { user, toast, refreshMessages } = useApp();
  const [bubbles, setBubbles] = useState<ChatBubble[]>([]);
  const [text, setText] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [asking, setAsking] = useState(false);
  const [when, setWhen] = useState("");
  const [busy, setBusy] = useState(false);
  const typingStart = useRef<number | null>(null);
  const voiceMs = useRef<number | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    try {
      const q = new URLSearchParams({ instanceId: chat.instanceId, jid: chat.jid });
      setBubbles((await api<Paginated<ChatBubble>>("GET", `/chats/messages?${q}`)).items);
    } catch {
      /* */
    }
  }, [chat.instanceId, chat.jid]);

  useEffect(() => {
    load();
    const fn = () => load();
    window.addEventListener("chat-incoming", fn);
    return () => window.removeEventListener("chat-incoming", fn);
  }, [load]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: "end" });
  }, [bubbles]);

  const isAudio = !!file && file.type.startsWith("audio/");
  const canSend = (text.trim() || file) && !busy;

  const openAsk = () => {
    const d = new Date(Date.now() + 3600_000);
    const p = (n: number) => String(n).padStart(2, "0");
    setWhen(`${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`);
    setAsking(true);
  };

  const send = async () => {
    setBusy(true);
    try {
      let mediaId: string | undefined;
      if (file) mediaId = (await uploadMedia(file)).mediaId;
      const type = !file
        ? "TEXT"
        : file.type.startsWith("image/")
          ? "IMAGE"
          : file.type.startsWith("video/")
            ? "VIDEO"
            : file.type.startsWith("audio/")
              ? "AUDIO"
              : "DOCUMENT";
      await api("POST", "/messages", {
        instanceId: chat.instanceId,
        recipient: { jid: chat.jid, name: chat.name, kind: chat.kind, pictureUrl: chat.pictureUrl },
        type,
        body: type === "AUDIO" ? null : text.trim() || null,
        mediaId: mediaId ?? null,
        scheduledAt: new Date(when).toISOString(),
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        recurrence: "NONE",
        recurrenceDays: [],
        typingMs: clampTyping(
          type === "AUDIO" ? voiceMs.current : typingStart.current ? Date.now() - typingStart.current : null,
        ),
      });
      setText("");
      setFile(null);
      typingStart.current = null;
      voiceMs.current = null;
      setAsking(false);
      toast(`Programado para ${scheduleLabel(new Date(when).toISOString())} ✓`);
      await load();
      await refreshMessages();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al programar.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="page chatpage">
      <div className="chathead">
        <button className="btn ghost" onClick={onBack} style={{ transform: "rotate(180deg)" }}>
          <IconChevron size={20} />
        </button>
        <Avatar name={chat.name} url={chat.pictureUrl} size={38} />
        <div className="name" style={{ fontWeight: 600 }}>{chat.name}</div>
      </div>

      <div className="bubbles">
        {bubbles.length === 0 && <div className="empty">Sin mensajes que mostrar.</div>}
        {bubbles.map((b) => (
          <div key={b.id} className={`bubblerow ${b.direction === "in" ? "left" : "right"}`}>
            <div className={`bubble ${b.direction}`}>
              {b.type !== "TEXT" && <div className="hint" style={{ marginTop: 0 }}>{messagePreview(b.type, null)}</div>}
              {b.body && <div style={{ whiteSpace: "pre-wrap" }}>{b.body}</div>}
              <div className="bubblemeta">
                {b.direction === "scheduled" ? `Programado · ${scheduleLabel(b.at)}` : timeLabel(b.at)}
                {b.direction === "out" && (b.status === "DELIVERED" || b.status === "READ") && <IconCheck size={12} />}
              </div>
            </div>
          </div>
        ))}
        <div ref={bottomRef} />
      </div>

      {file && (
        <div className="kv" style={{ padding: "6px 0" }}>
          <span style={{ display: "flex", alignItems: "center", gap: 6 }}><IconPaperclip size={14} /> {file.name}</span>
          <button className="btn small secondary" onClick={() => setFile(null)}>Quitar</button>
        </div>
      )}

      <div className="chatinput">
        <label className="btn small secondary" style={{ cursor: "pointer" }}>
          <IconPaperclip size={16} />
          <input
            type="file"
            hidden
            accept="image/jpeg,image/png,image/webp,video/mp4,video/quicktime,application/pdf,audio/mpeg,audio/mp4,audio/x-m4a,audio/aac,audio/ogg,audio/webm,audio/wav"
            onChange={(e) => setFile(e.target.files?.[0] ?? null)}
          />
        </label>
        <div style={{ flexShrink: 0 }}>
          <VoiceRecorderMini onDone={(f, dur) => { setFile(f); voiceMs.current = dur ?? null; }} />
        </div>
        {isAudio ? (
          <div className="hint" style={{ flex: 1, marginTop: 0 }}>Nota de voz lista — se envía sin texto.</div>
        ) : (
          <input
            className="field"
            style={{ flex: 1 }}
            placeholder="Escribe un mensaje"
            value={text}
            onChange={(e) => {
              if (!typingStart.current && e.target.value) typingStart.current = Date.now();
              setText(e.target.value);
            }}
            onKeyDown={(e) => e.key === "Enter" && canSend && openAsk()}
          />
        )}
        <button className="btn small" disabled={!canSend} onClick={openAsk}>
          <IconSend size={16} />
        </button>
      </div>

      {asking && (
        <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && setAsking(false)}>
          <div className="sheet" style={{ maxWidth: 420 }}>
            <div className="sheethead"><h2>¿Cuándo se envía?</h2></div>
            <div className="chips" style={{ paddingBottom: 8 }}>
              {QUICK_PERIODS.map(([k, label]) => (
                <button
                  key={k}
                  className={`chip ${quickActive(when, user.quickHours[k]) ? "active" : ""}`}
                  onClick={() => {
                    const d = quickDate(user.quickHours[k]);
                    const p = (n: number) => String(n).padStart(2, "0");
                    setWhen(`${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`);
                  }}
                >
                  {label}
                </button>
              ))}
            </div>
            <input className="field" type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} />
            <button className="btn" style={{ marginTop: 14 }} disabled={busy} onClick={send}>
              {busy ? <span className="spin" /> : "Programar"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// versión compacta del grabador para la barra del chat (solo icono)
function VoiceRecorderMini({ onDone }: { onDone: (f: File, durationMs?: number) => void }) {
  return <VoiceRecorderButton onDone={onDone} compact />;
}
