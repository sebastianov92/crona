import { useEffect, useState } from "react";
import { api, ApiError, uploadMedia } from "../api";
import { useApp } from "../App";
import { Avatar, DayDots, MediaImg, Sheet, Toggle, logLabel, messagePreview, recurrenceLabel, scheduleLabel, statusLabel } from "../lib";
import type { MessageLog, Paginated, Recipient, RecipientKind, Recurrence, ScheduledMessage } from "../types";
import { IconCheckCircle, IconCircle, IconPaperclip, IconPlus, IconRefresh, IconRepeat, IconReply } from "../icons";

const FILTERS = [
  { id: "all", label: "Todos" },
  { id: "contacts", label: "Contactos" },
  { id: "groups", label: "Grupos" },
  { id: "recurring", label: "Recurrentes" },
  { id: "auto", label: "Automáticas" },
] as const;

export default function Scheduled() {
  const { upcoming, instances } = useApp();
  const [filter, setFilter] = useState<(typeof FILTERS)[number]["id"]>("all");
  const [search, setSearch] = useState("");
  const [compose, setCompose] = useState(false);
  const [selected, setSelected] = useState<ScheduledMessage | null>(null);

  const disconnected = instances.some((i) => i.status === "DISCONNECTED");

  const filtered = upcoming
    .filter((m) =>
      filter === "all"
        ? true
        : filter === "contacts"
          ? m.recipientKind === "CONTACT"
          : filter === "groups"
            ? m.recipientKind === "GROUP"
            : filter === "recurring"
              ? m.recurrence !== "NONE"
              : m.isAutoReply,
    )
    .filter(
      (m) =>
        !search ||
        m.recipientName.toLowerCase().includes(search.toLowerCase()) ||
        (m.body ?? "").toLowerCase().includes(search.toLowerCase()),
    );

  return (
    <div className="page">
      <h1 className="pagetitle">Programados</h1>
      {disconnected && <div className="banner">Tu WhatsApp está desconectado — los envíos fallarán. Re-escanea el QR en Ajustes → Instancias.</div>}
      <input className="field" placeholder="Buscar" value={search} onChange={(e) => setSearch(e.target.value)} style={{ marginBottom: 12 }} />
      <div className="chips">
        {FILTERS.map((f) => (
          <button key={f.id} className={`chip ${filter === f.id ? "active" : ""}`} onClick={() => setFilter(f.id)}>
            {f.label}
          </button>
        ))}
      </div>
      <div className="card">
        {filtered.length === 0 && <div className="empty">No tienes mensajes programados.<br />Toca + para crear el primero.</div>}
        {filtered.map((m) => (
          <button key={m.id} className="row" onClick={() => setSelected(m)}>
            <Avatar name={m.recipientName} url={m.recipientPictureUrl} />
            <div className="main">
              <div className="name">{m.recipientName}</div>
              <div className="sub">{messagePreview(m.type, m.body)}</div>
            </div>
            <div className="right">
              <div className="time">
                {m.isAutoReply && <IconReply size={12} />}
                {m.recurrence !== "NONE" && <IconRepeat size={12} />}
                {scheduleLabel(m.nextRunAt)}
              </div>
              <div className="state">{statusLabel[m.status]}</div>
            </div>
          </button>
        ))}
      </div>
      <button className="fab" onClick={() => setCompose(true)}><IconPlus size={26} /></button>
      {compose && <ComposeSheet onClose={() => setCompose(false)} />}
      {selected && <DetailSheet id={selected.id} onClose={() => setSelected(null)} />}
    </div>
  );
}

// ── Compose ──────────────────────────────────────────────

const COMMON_TZ = [
  Intl.DateTimeFormat().resolvedOptions().timeZone,
  "America/Guayaquil", "America/Bogota", "America/Lima", "America/Mexico_City",
  "America/New_York", "America/Los_Angeles", "America/Santiago",
  "America/Argentina/Buenos_Aires", "America/Sao_Paulo", "America/Caracas",
  "Europe/Madrid", "Europe/London", "Europe/Paris",
].filter((v, i, a) => a.indexOf(v) === i);

function localInputValue(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

function ComposeSheet({ onClose }: { onClose: () => void }) {
  const { instances, refreshMessages, toast } = useApp();
  const [instanceId, setInstanceId] = useState(instances[0]?.id ?? "");
  const [recipients, setRecipients] = useState<Recipient[]>([]);
  const [showPicker, setShowPicker] = useState(false);
  const [text, setText] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [when, setWhen] = useState(() => localInputValue(new Date(Date.now() + 3600_000)));
  const [tz, setTz] = useState(COMMON_TZ[0]);
  const [recurrence, setRecurrence] = useState<Recurrence>("NONE");
  const [days, setDays] = useState<Set<number>>(new Set());
  const [randomDelay, setRandomDelay] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const canSubmit = recipients.length > 0 && instanceId && (text.trim() || file) && !busy;

  const submit = async () => {
    setBusy(true);
    setError("");
    try {
      let mediaId: string | undefined;
      if (file) mediaId = (await uploadMedia(file)).mediaId;
      const type = !file ? "TEXT" : file.type.startsWith("image/") ? "IMAGE" : file.type.startsWith("video/") ? "VIDEO" : "DOCUMENT";
      for (const r of recipients) {
        await api("POST", "/messages", {
          instanceId,
          recipient: { jid: r.jid, name: r.displayName, kind: r.kind, pictureUrl: r.pictureUrl },
          type,
          body: text.trim() || null,
          mediaId: mediaId ?? null,
          scheduledAt: new Date(when).toISOString(),
          timezone: tz,
          recurrence,
          recurrenceDays: recurrence === "WEEKLY" ? [...days].sort() : [],
          randomDelay: recurrence !== "NONE" && randomDelay,
        });
      }
      await refreshMessages();
      toast(`Programado para ${recipients.length} destinatario${recipients.length > 1 ? "s" : ""} ✓`);
      onClose();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Error al programar.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title="Nuevo mensaje" onClose={onClose}>
      {instances.length > 1 && (
        <>
          <label className="label">Enviar desde</label>
          <select className="field" value={instanceId} onChange={(e) => setInstanceId(e.target.value)}>
            {instances.map((i) => (
              <option key={i.id} value={i.id}>{i.name}</option>
            ))}
          </select>
        </>
      )}

      <label className="label">Destinatarios</label>
      <div className="card">
        {recipients.map((r) => (
          <div key={r.jid} className="row" style={{ cursor: "default" }}>
            <Avatar name={r.displayName} url={r.pictureUrl} size={34} />
            <div className="main"><div className="name" style={{ fontSize: 14 }}>{r.displayName}</div></div>
            <button className="btn small secondary" onClick={() => setRecipients(recipients.filter((x) => x.jid !== r.jid))}>✕</button>
          </div>
        ))}
        <button className="row" onClick={() => setShowPicker(true)}>
          <div className="main" style={{ color: "var(--accent)", display: "flex", alignItems: "center", gap: 6 }}><IconPlus size={15} /> {recipients.length ? "Agregar más" : "Elegir contactos o grupos"}</div>
        </button>
      </div>

      <label className="label">Mensaje</label>
      <textarea className="field" placeholder="Escribe un mensaje" value={text} onChange={(e) => setText(e.target.value)} />
      <div className="hint">Variables: {"{nombre}"} nombre · {"{primer_nombre}"} primer nombre · {"{fecha}"} fecha · {"{dia}"} día</div>

      <label className="label">Adjunto (foto, video o PDF)</label>
      {file ? (
        <div className="kv">
          <span style={{ display: "flex", alignItems: "center", gap: 6 }}><IconPaperclip size={14} /> {file.name}</span>
          <button className="btn small secondary" onClick={() => setFile(null)}>Quitar</button>
        </div>
      ) : (
        <input type="file" accept="image/jpeg,image/png,image/webp,video/mp4,video/quicktime,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
      )}

      <label className="label">Fecha y hora</label>
      <input className="field" type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} />
      <label className="label">Zona horaria</label>
      <select className="field" value={tz} onChange={(e) => setTz(e.target.value)}>
        {COMMON_TZ.map((z) => (
          <option key={z} value={z}>{z.split("/").pop()?.replace(/_/g, " ")}</option>
        ))}
      </select>

      <label className="label">Repetir</label>
      <select className="field" value={recurrence} onChange={(e) => setRecurrence(e.target.value as Recurrence)}>
        {(Object.keys(recurrenceLabel) as Recurrence[]).map((r) => (
          <option key={r} value={r}>{recurrenceLabel[r]}{r === "YEARLY" ? " (cumpleaños)" : ""}</option>
        ))}
      </select>
      {recurrence === "WEEKLY" && (
        <div style={{ marginTop: 10 }}>
          <DayDots value={days} onChange={setDays} />
        </div>
      )}
      {recurrence !== "NONE" && (
        <div className="kv" style={{ marginTop: 8 }}>
          <span>
            Variar hora aleatoriamente
            <div className="hint">+1 a 5 min por envío — evita el patrón exacto</div>
          </span>
          <Toggle on={randomDelay} onChange={setRandomDelay} />
        </div>
      )}

      {error && <div className="error">{error}</div>}
      <button className="btn" style={{ marginTop: 16 }} disabled={!canSubmit} onClick={submit}>
        {busy ? <span className="spin" /> : "Programar"}
      </button>

      {showPicker && (
        <RecipientPicker
          instanceId={instanceId}
          onDone={(picked) => {
            setRecipients((prev) => [...prev, ...picked.filter((p) => !prev.some((x) => x.jid === p.jid))]);
            setShowPicker(false);
          }}
          onClose={() => setShowPicker(false)}
        />
      )}
    </Sheet>
  );
}

// ── Picker de destinatarios ──────────────────────────────

function RecipientPicker({ instanceId, onDone, onClose }: { instanceId: string; onDone: (r: Recipient[]) => void; onClose: () => void }) {
  const { toast } = useApp();
  const [kind, setKind] = useState<RecipientKind>("CONTACT");
  const [search, setSearch] = useState("");
  const [items, setItems] = useState<Recipient[]>([]);
  const [selected, setSelected] = useState<Recipient[]>([]);
  const [syncing, setSyncing] = useState(false);

  useEffect(() => {
    const t = setTimeout(async () => {
      try {
        const q = new URLSearchParams({ kind, ...(search ? { search } : {}) });
        setItems((await api<Paginated<Recipient>>("GET", `/instances/${instanceId}/recipients?${q}`)).items);
      } catch {
        /* */
      }
    }, 250);
    return () => clearTimeout(t);
  }, [kind, search, instanceId]);

  const toggle = (r: Recipient) =>
    setSelected((prev) => (prev.some((x) => x.jid === r.jid) ? prev.filter((x) => x.jid !== r.jid) : [...prev, r]));

  return (
    <Sheet
      title="Destinatarios"
      onClose={onClose}
      actions={
        selected.length ? (
          <button className="btn small" onClick={() => onDone(selected)}>Listo ({selected.length})</button>
        ) : (
          <button
            className="btn small secondary"
            disabled={syncing}
            onClick={async () => {
              setSyncing(true);
              try {
                const r = await api<{ contacts: number; groups: number }>("POST", `/instances/${instanceId}/sync`);
                toast(`Sincronizado: ${r.contacts} contactos, ${r.groups} grupos`);
                setSearch("");
              } catch (e) {
                toast(e instanceof ApiError ? e.message : "Error al sincronizar");
              } finally {
                setSyncing(false);
              }
            }}
          >
            {syncing ? <span className="spin dark" /> : <IconRefresh size={16} />}
          </button>
        )
      }
    >
      <div className="seg" style={{ marginBottom: 10 }}>
        <button className={kind === "CONTACT" ? "active" : ""} onClick={() => setKind("CONTACT")}>Contactos</button>
        <button className={kind === "GROUP" ? "active" : ""} onClick={() => setKind("GROUP")}>Grupos</button>
      </div>
      <input className="field" placeholder="Buscar" value={search} onChange={(e) => setSearch(e.target.value)} style={{ marginBottom: 10 }} />
      <div className="card">
        {items.length === 0 && <div className="empty">Sin resultados. Usa el botón de sincronizar (arriba a la derecha).</div>}
        {items.map((r) => {
          const on = selected.some((x) => x.jid === r.jid);
          return (
            <button key={r.jid} className="row" onClick={() => toggle(r)}>
              <Avatar name={r.displayName} url={r.pictureUrl} size={38} />
              <div className="main">
                <div className="name" style={{ fontSize: 14 }}>{r.displayName}</div>
                {r.phoneNumber && <div className="sub">{r.phoneNumber}</div>}
              </div>
              <span style={{ color: on ? "var(--accent)" : "var(--text2)", display: "flex" }}>{on ? <IconCheckCircle size={20} /> : <IconCircle size={20} />}</span>
            </button>
          );
        })}
      </div>
    </Sheet>
  );
}

// ── Detalle ──────────────────────────────────────────────

function DetailSheet({ id, onClose }: { id: string; onClose: () => void }) {
  const { refreshMessages, toast } = useApp();
  const [detail, setDetail] = useState<{ message: ScheduledMessage; logs: MessageLog[] } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = async () => setDetail(await api("GET", `/messages/${id}`));
  useEffect(() => {
    load().catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  const act = async (fn: () => Promise<unknown>, closeAfter = false) => {
    setBusy(true);
    try {
      await fn();
      await refreshMessages();
      if (closeAfter) onClose();
      else await load();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error");
    } finally {
      setBusy(false);
    }
  };

  if (!detail) return null;
  const m = detail.message;
  const editable = (m.status === "ACTIVE" || m.status === "PAUSED") && new Date(m.nextRunAt).getTime() > Date.now() + 60000;

  return (
    <Sheet title={m.recipientName} onClose={onClose}>
      <div className="kv"><span className="k">Estado</span><span>{statusLabel[m.status]}</span></div>
      <div className="kv"><span className="k">Envío</span><span>{scheduleLabel(m.nextRunAt)}</span></div>
      {m.recurrence !== "NONE" && (
        <div className="kv"><span className="k">Repite</span><span>{recurrenceLabel[m.recurrence]}{m.randomDelay ? " · ±1-5 min" : ""}</span></div>
      )}
      {m.isAutoReply && <div className="kv"><span className="k">Origen</span><span>Respuesta automática</span></div>}
      {m.lastError && <div className="error">Último error: {m.lastError}</div>}

      {m.mediaId && <div style={{ margin: "12px 0" }}><MediaImg mediaId={m.mediaId} type={m.type} /></div>}
      {m.body && <p style={{ margin: "12px 0", whiteSpace: "pre-wrap" }}>{m.body}</p>}

      {detail.logs.length > 0 && (
        <>
          <label className="label">Envíos</label>
          {detail.logs.map((l) => (
            <div key={l.id} className="kv">
              <span className="k">{new Date(l.runAt).toLocaleString("es", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })}</span>
              <span style={{ color: l.status === "FAILED" ? "var(--danger)" : undefined }}>{logLabel[l.status]}</span>
            </div>
          ))}
        </>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 16 }}>
        {(m.status === "ACTIVE" || m.status === "PAUSED") && (
          <button className="btn" disabled={busy} onClick={() => confirm(`¿Enviar ahora a ${m.recipientName}?`) && act(() => api("POST", `/messages/${m.id}/send-now`), true)}>
            Enviar ahora
          </button>
        )}
        {m.status === "FAILED" && (
          <button className="btn" disabled={busy} onClick={() => act(() => api("POST", `/messages/${m.id}/send-now`), true)}>Reintentar</button>
        )}
        {editable && (
          <button className="btn secondary" disabled={busy} onClick={() => act(() => api("PATCH", `/messages/${m.id}`, { status: m.status === "PAUSED" ? "ACTIVE" : "PAUSED" }))}>
            {m.status === "PAUSED" ? "Reanudar" : "Pausar"}
          </button>
        )}
        <button className="btn secondary" disabled={busy} onClick={() => act(() => api("POST", `/messages/${m.id}/duplicate`), true)}>Duplicar</button>
        {editable && (
          <button className="btn danger" disabled={busy} onClick={() => confirm("¿Cancelar este envío?") && act(() => api("POST", `/messages/${m.id}/cancel`), true)}>
            Cancelar envío
          </button>
        )}
        {["CANCELLED", "COMPLETED", "FAILED"].includes(m.status) && (
          <button className="btn danger" disabled={busy} onClick={() => act(() => api("DELETE", `/messages/${m.id}`), true)}>Eliminar</button>
        )}
      </div>
    </Sheet>
  );
}
