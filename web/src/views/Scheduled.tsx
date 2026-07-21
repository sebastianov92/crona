import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError, fetchAll, uploadMedia } from "../api";
import { useApp } from "../App";
import { Avatar, DayDots, MediaImg, Sheet, Toggle, logLabel, messagePreview, recurrenceLabel, scheduleLabel, statusLabel } from "../lib";
import { quickDate, shownName } from "../types";
import type { ContactList, MessageLog, Paginated, Recipient, RecipientKind, Recurrence, ScheduledMessage } from "../types";
import { IconCheckCircle, IconCircle, IconMic, IconPaperclip, IconPencil, IconPhonePlus, IconPlus, IconRefresh, IconRepeat, IconReply, IconStop, IconTrash } from "../icons";

export const QUICK_PERIODS = [
  ["morning", "Mañana"],
  ["afternoon", "Tarde"],
  ["evening", "Noche"],
] as const;

export const clampTyping = (ms: number | null): number | null =>
  ms === null ? null : Math.max(1500, Math.min(25_000, Math.round(ms)));

/** ¿La hora elegida cae dentro de la franja de este botón rápido? (para pintarlo activo) */
export const quickActive = (when: string, r: { start: number; end: number }): boolean => {
  const d = new Date(when);
  if (Number.isNaN(d.getTime())) return false;
  const m = d.getHours() * 60 + d.getMinutes();
  return m >= r.start && m <= Math.max(r.start + 5, r.end);
};

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
      {disconnected && <div className="banner">Tu WhatsApp está desconectado — los envíos fallarán. Re-escanea el QR en Ajustes → Conectar a WhatsApp.</div>}
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
  const { user, instances, refreshMessages, toast } = useApp();
  const [instanceId, setInstanceId] = useState(instances[0]?.id ?? "");
  const [recipients, setRecipients] = useState<Recipient[]>([]);
  const [showPicker, setShowPicker] = useState(false);
  const [text, setText] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const typingStart = useRef<number | null>(null); // primer caracter escrito
  const voiceMs = useRef<number | null>(null); // duración de la nota de voz grabada
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
      const type = !file
        ? "TEXT"
        : file.type.startsWith("image/")
          ? "IMAGE"
          : file.type.startsWith("video/")
            ? "VIDEO"
            : file.type.startsWith("audio/")
              ? "AUDIO"
              : "DOCUMENT";
      const typingMs = clampTyping(
        type === "AUDIO" ? voiceMs.current : typingStart.current ? Date.now() - typingStart.current : null,
      );
      // Varios destinatarios: misma hora para todos — el worker los envía UNO POR UNO
      // (escribiendo… → envía → pausa aleatoria 3-9 s → siguiente), nunca dos a la vez.
      for (const r of recipients) {
        await api("POST", "/messages", {
          instanceId,
          recipient: { jid: r.jid, name: shownName(r), kind: r.kind, pictureUrl: r.pictureUrl },
          type,
          body: type === "AUDIO" ? null : text.trim() || null,
          mediaId: mediaId ?? null,
          scheduledAt: new Date(when).toISOString(),
          timezone: tz,
          recurrence,
          recurrenceDays: recurrence === "WEEKLY" ? [...days].sort() : [],
          randomDelay: recurrence !== "NONE" && randomDelay,
          typingMs,
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
            <Avatar name={shownName(r)} url={r.pictureUrl} size={34} />
            <div className="main"><div className="name" style={{ fontSize: 14 }}>{shownName(r)}</div></div>
            <button className="btn small secondary" onClick={() => setRecipients(recipients.filter((x) => x.jid !== r.jid))}>✕</button>
          </div>
        ))}
        <button className="row" onClick={() => setShowPicker(true)}>
          <div className="main" style={{ color: "var(--accent)", display: "flex", alignItems: "center", gap: 6 }}><IconPlus size={15} /> {recipients.length ? "Agregar más" : "Elegir contactos o grupos"}</div>
        </button>
      </div>

      <label className="label">Mensaje</label>
      {file?.type.startsWith("audio/") ? (
        <div className="hint">Las notas de voz se envían solas, sin texto.</div>
      ) : (
        <>
          <textarea
            className="field"
            placeholder="Escribe un mensaje"
            value={text}
            onChange={(e) => {
              if (!typingStart.current && e.target.value) typingStart.current = Date.now();
              setText(e.target.value);
            }}
          />
          <div className="hint">Variables: {"{nombre}"} nombre · {"{primer_nombre}"} primer nombre · {"{fecha}"} fecha · {"{dia}"} día</div>
        </>
      )}

      <label className="label">Adjunto (foto, video, PDF o audio)</label>
      {file ? (
        <div className="kv">
          <span style={{ display: "flex", alignItems: "center", gap: 6 }}><IconPaperclip size={14} /> {file.name}</span>
          <button className="btn small secondary" onClick={() => setFile(null)}>Quitar</button>
        </div>
      ) : (
        <div style={{ display: "flex", gap: 8 }}>
          <label className="filebtn">
            <IconPaperclip size={16} />
            Adjuntar archivo
            <input
              type="file"
              hidden
              accept="image/jpeg,image/png,image/webp,video/mp4,video/quicktime,application/pdf,audio/mpeg,audio/mp4,audio/x-m4a,audio/aac,audio/ogg,audio/webm,audio/wav"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            />
          </label>
          <VoiceRecorderButton onDone={(f, dur) => { setFile(f); voiceMs.current = dur ?? null; }} />
        </div>
      )}

      <label className="label">Fecha y hora</label>
      <div className="chips" style={{ paddingBottom: 8 }}>
        {QUICK_PERIODS.map(([k, label]) => (
          <button
            key={k}
            className={`chip ${quickActive(when, user.quickHours[k]) ? "active" : ""}`}
            onClick={() => setWhen(localInputValue(quickDate(user.quickHours[k])))}
          >
            {label}
          </button>
        ))}
      </div>
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

// ── Grabador de notas de voz ─────────────────────────────

export function VoiceRecorderButton({ onDone, compact = false }: { onDone: (f: File, durationMs?: number) => void; compact?: boolean }) {
  const { toast } = useApp();
  const [rec, setRec] = useState<MediaRecorder | null>(null);
  const [secs, setSecs] = useState(0);
  const startedAt = useRef(0);

  useEffect(() => {
    if (!rec) return;
    const t = setInterval(() => setSecs((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, [rec]);

  const start = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      // Chrome/Firefox: webm/opus · Safari: mp4 (aac)
      const mime = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? "audio/webm;codecs=opus"
        : MediaRecorder.isTypeSupported("audio/mp4")
          ? "audio/mp4"
          : "";
      const r = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
      const chunks: Blob[] = [];
      r.ondataavailable = (e) => e.data.size && chunks.push(e.data);
      r.onstop = () => {
        stream.getTracks().forEach((t) => t.stop());
        const type = (r.mimeType || "audio/webm").split(";")[0];
        const ext = type.includes("mp4") ? "m4a" : type.includes("ogg") ? "ogg" : "webm";
        onDone(new File(chunks, `nota-de-voz.${ext}`, { type }), Date.now() - startedAt.current);
      };
      r.start();
      startedAt.current = Date.now();
      setSecs(0);
      setRec(r);
    } catch {
      toast("No se pudo acceder al micrófono. Revisa los permisos del navegador.");
    }
  };

  const stop = () => {
    rec?.stop();
    setRec(null);
  };

  const mmss = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`;
  if (compact) {
    return (
      <button
        type="button"
        className="btn small secondary"
        style={rec ? { color: "var(--danger)" } : undefined}
        onClick={() => (rec ? stop() : start())}
      >
        {rec ? <IconStop size={16} /> : <IconMic size={16} />}
        {rec && mmss}
      </button>
    );
  }
  return (
    <button
      type="button"
      className="filebtn"
      style={rec ? { borderColor: "var(--danger)", color: "var(--danger)" } : undefined}
      onClick={() => (rec ? stop() : start())}
    >
      {rec ? <IconStop size={16} /> : <IconMic size={16} />}
      {rec ? `Detener (${mmss})` : "Grabar nota de voz"}
    </button>
  );
}

// ── Picker de destinatarios ──────────────────────────────

// Prefijos telefónicos ITU por región ISO-3166 (mismo mapa que la app nativa)
const DIAL_RAW =
  "AF:93,AL:355,DZ:213,AD:376,AO:244,AG:1268,AR:54,AM:374,AU:61,AT:43,AZ:994,BS:1242,BH:973,BD:880,BB:1246," +
  "BY:375,BE:32,BZ:501,BJ:229,BT:975,BO:591,BA:387,BW:267,BR:55,BN:673,BG:359,BF:226,BI:257,KH:855,CM:237," +
  "CA:1,CV:238,CF:236,TD:235,CL:56,CN:86,CO:57,KM:269,CG:242,CD:243,CR:506,CI:225,HR:385,CU:53,CY:357,CZ:420," +
  "DK:45,DJ:253,DM:1767,DO:1809,EC:593,EG:20,SV:503,GQ:240,ER:291,EE:372,SZ:268,ET:251,FJ:679,FI:358,FR:33," +
  "GA:241,GM:220,GE:995,DE:49,GH:233,GR:30,GD:1473,GT:502,GN:224,GW:245,GY:592,HT:509,HN:504,HK:852,HU:36," +
  "IS:354,IN:91,ID:62,IR:98,IQ:964,IE:353,IL:972,IT:39,JM:1876,JP:81,JO:962,KZ:7,KE:254,KI:686,KW:965,KG:996," +
  "LA:856,LV:371,LB:961,LS:266,LR:231,LY:218,LI:423,LT:370,LU:352,MO:853,MG:261,MW:265,MY:60,MV:960,ML:223," +
  "MT:356,MH:692,MR:222,MU:230,MX:52,FM:691,MD:373,MC:377,MN:976,ME:382,MA:212,MZ:258,MM:95,NA:264,NR:674," +
  "NP:977,NL:31,NZ:64,NI:505,NE:227,NG:234,KP:850,MK:389,NO:47,OM:968,PK:92,PW:680,PA:507,PG:675,PY:595,PE:51," +
  "PH:63,PL:48,PT:351,PR:1787,QA:974,RO:40,RU:7,RW:250,KN:1869,LC:1758,VC:1784,WS:685,SM:378,ST:239,SA:966," +
  "SN:221,RS:381,SC:248,SL:232,SG:65,SK:421,SI:386,SB:677,SO:252,ZA:27,KR:82,SS:211,ES:34,LK:94,SD:249,SR:597," +
  "SE:46,CH:41,SY:963,TW:886,TJ:992,TZ:255,TH:66,TL:670,TG:228,TO:676,TT:1868,TN:216,TR:90,TM:993,TV:688," +
  "UG:256,UA:380,AE:971,GB:44,US:1,UY:598,UZ:998,VU:678,VE:58,VN:84,YE:967,ZM:260,ZW:263";

const COUNTRIES = (() => {
  const names = new Intl.DisplayNames(["es"], { type: "region" });
  const flag = (region: string) => [...region].map((c) => String.fromCodePoint(127397 + c.charCodeAt(0))).join("");
  return DIAL_RAW.split(",")
    .map((pair) => {
      const [region, code] = pair.split(":");
      return { region, code, name: names.of(region) ?? region, flag: flag(region) };
    })
    .sort((a, b) => a.name.localeCompare(b.name, "es"));
})();

function ManualNumberForm({ onAdd }: { onAdd: (r: Recipient) => void }) {
  const [region, setRegion] = useState("EC");
  const [number, setNumber] = useState("");
  const country = COUNTRIES.find((c) => c.region === region)!;
  const digits = number.replace(/\D/g, "");
  const normalized = digits.startsWith("0") ? digits.slice(1) : digits; // 0999… → 999…
  const full = country.code + normalized;
  const valid = normalized.length >= 7 && full.length <= 15;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8, padding: "10px 14px", borderBottom: "1px solid var(--border)" }}>
      <div style={{ display: "flex", gap: 8 }}>
        <select className="field" style={{ flex: 1 }} value={region} onChange={(e) => setRegion(e.target.value)}>
          {COUNTRIES.map((c) => (
            <option key={c.region} value={c.region}>{c.flag} {c.name} (+{c.code})</option>
          ))}
        </select>
        <input
          className="field"
          style={{ flex: 1 }}
          placeholder="Número (ej. 991234567)"
          inputMode="numeric"
          autoFocus
          value={number}
          onChange={(e) => setNumber(e.target.value)}
        />
      </div>
      <div className="hint">{valid ? `Se enviará a +${full}` : "Escribe el número sin el código de país."}</div>
      <button
        className="btn small"
        style={{ alignSelf: "flex-end" }}
        disabled={!valid}
        onClick={() =>
          onAdd({
            id: `manual-${full}`,
            jid: `${full}@s.whatsapp.net`,
            displayName: `+${full}`,
            alias: null,
            pictureUrl: null,
            kind: "CONTACT",
            phoneNumber: full,
          })
        }
      >
        Agregar
      </button>
    </div>
  );
}

function RecipientPicker({ instanceId, onDone, onClose }: { instanceId: string; onDone: (r: Recipient[]) => void; onClose: () => void }) {
  const { toast } = useApp();
  const [tab, setTab] = useState<"CONTACT" | "GROUP" | "LISTS">("CONTACT");
  const kind: RecipientKind = tab === "GROUP" ? "GROUP" : "CONTACT";
  const [search, setSearch] = useState("");
  const [items, setItems] = useState<Recipient[]>([]);
  const [selected, setSelected] = useState<Recipient[]>([]);
  const [syncing, setSyncing] = useState(false);
  const [showManual, setShowManual] = useState(false);
  const [manualAdded, setManualAdded] = useState<Recipient[]>([]);
  const [lists, setLists] = useState<ContactList[]>([]);
  const [editingList, setEditingList] = useState(false);
  const [loading, setLoading] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);

  const loadLists = useCallback(async () => {
    try {
      setLists((await api<Paginated<ContactList>>("GET", "/lists")).items.filter((l) => l.instanceId === instanceId));
    } catch {
      /* */
    }
  }, [instanceId]);

  useEffect(() => {
    if (tab === "LISTS") {
      loadLists();
      return;
    }
    let alive = true;
    const t = setTimeout(async () => {
      setLoading(true);
      try {
        // todas las páginas: la agenda puede tener cientos de contactos
        const all = await fetchAll<Recipient>(`/instances/${instanceId}/recipients`, { kind, ...(search ? { search } : {}) });
        if (alive) setItems(all);
      } catch {
        /* */
      } finally {
        if (alive) setLoading(false);
      }
    }, 250);
    return () => {
      alive = false;
      clearTimeout(t);
    };
  }, [tab, kind, search, instanceId, loadLists]);

  const memberToRecipient = (m: ContactList["members"][number]): Recipient => ({
    id: `list-${m.jid}`,
    jid: m.jid,
    displayName: m.name,
    alias: null,
    pictureUrl: m.pictureUrl,
    kind: m.kind,
    phoneNumber: null,
  });

  const toggle = (r: Recipient) =>
    setSelected((prev) => (prev.some((x) => x.jid === r.jid) ? prev.filter((x) => x.jid !== r.jid) : [...prev, r]));

  const rename = async (r: Recipient) => {
    const input = window.prompt(`Apodo para "${r.displayName}" (vacío para quitarlo):`, r.alias ?? "");
    if (input === null) return;
    const alias = input.trim() || null;
    try {
      const updated = await api<Recipient>("PATCH", `/instances/${instanceId}/recipients/${r.id}`, { alias });
      setItems((prev) => prev.map((x) => (x.id === r.id ? updated : x)));
      setSelected((prev) => prev.map((x) => (x.id === r.id ? updated : x)));
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al renombrar");
    }
  };

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
        <button className={tab === "CONTACT" ? "active" : ""} onClick={() => setTab("CONTACT")}>Contactos</button>
        <button className={tab === "GROUP" ? "active" : ""} onClick={() => setTab("GROUP")}>Grupos</button>
        <button className={tab === "LISTS" ? "active" : ""} onClick={() => setTab("LISTS")}>Listas</button>
      </div>
      {tab === "LISTS" ? (
        <div className="card">
          <button className="row" onClick={() => setEditingList(true)}>
            <span style={{ color: "var(--accent)", display: "flex", alignItems: "center", gap: 8 }}>
              <IconPlus size={16} /> Nueva lista
            </span>
          </button>
          {editingList && (
            <ListEditor
              instanceId={instanceId}
              onSaved={() => { setEditingList(false); loadLists(); }}
              onCancel={() => setEditingList(false)}
            />
          )}
          {lists.length === 0 && !editingList && (
            <div className="empty">Crea una lista para programar a varios contactos de una sola vez.</div>
          )}
          {lists.map((l) => {
            const allIn = l.members.every((m) => selected.some((x) => x.jid === m.jid));
            return (
              <button
                key={l.id}
                className="row"
                onClick={() => {
                  const rs = l.members.map(memberToRecipient);
                  setSelected((prev) =>
                    allIn
                      ? prev.filter((x) => !l.members.some((m) => m.jid === x.jid))
                      : [...prev, ...rs.filter((r) => !prev.some((x) => x.jid === r.jid))],
                  );
                }}
              >
                <Avatar name={l.name} url={null} size={38} />
                <div className="main">
                  <div className="name" style={{ fontSize: 14 }}>{l.name}</div>
                  <div className="sub">{l.members.length} contacto{l.members.length !== 1 ? "s" : ""} · se envía con 3-9 s entre cada uno</div>
                </div>
                <span
                  title="Eliminar lista"
                  style={{ color: "var(--text2)", display: "flex", padding: 6 }}
                  onClick={async (e) => {
                    e.stopPropagation();
                    if (!confirm(`¿Eliminar la lista "${l.name}"?`)) return;
                    try {
                      await api("DELETE", `/lists/${l.id}`);
                      loadLists();
                    } catch { toast("Error al eliminar la lista"); }
                  }}
                >
                  <IconTrash size={15} />
                </span>
                <span style={{ color: allIn ? "var(--accent)" : "var(--text2)", display: "flex" }}>
                  {allIn ? <IconCheckCircle size={20} /> : <IconCircle size={20} />}
                </span>
              </button>
            );
          })}
        </div>
      ) : (
      <>
      <input
        ref={searchRef}
        className="field"
        placeholder="Buscar por nombre o número"
        autoFocus
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        style={{ marginBottom: 10 }}
      />
      <div className="card">
        {kind === "CONTACT" && (
          <button className="row" onClick={() => setShowManual((v) => !v)}>
            <span style={{ color: "var(--accent)", display: "flex", alignItems: "center", gap: 8 }}>
              <IconPhonePlus size={18} /> Enviar a un número
            </span>
          </button>
        )}
        {kind === "CONTACT" && showManual && (
          <ManualNumberForm
            onAdd={(r) => {
              setManualAdded((prev) => (prev.some((x) => x.jid === r.jid) ? prev : [...prev, r]));
              setSelected((prev) => (prev.some((x) => x.jid === r.jid) ? prev : [...prev, r]));
              setShowManual(false);
            }}
          />
        )}
        {kind === "CONTACT" &&
          manualAdded.map((r) => {
            const on = selected.some((x) => x.jid === r.jid);
            return (
              <button key={r.jid} className="row" onClick={() => toggle(r)}>
                <Avatar name={r.displayName} url={null} size={38} />
                <div className="main">
                  <div className="name" style={{ fontSize: 14 }}>{r.displayName}</div>
                  <div className="sub">Número escrito a mano</div>
                </div>
                <span style={{ color: on ? "var(--accent)" : "var(--text2)", display: "flex" }}>{on ? <IconCheckCircle size={20} /> : <IconCircle size={20} />}</span>
              </button>
            );
          })}
        {items.length === 0 && <div className="empty">Sin resultados. Usa el botón de sincronizar (arriba a la derecha).</div>}
        {items.map((r) => {
          const on = selected.some((x) => x.jid === r.jid);
          return (
            <button key={r.jid} className="row" onClick={() => toggle(r)}>
              <Avatar name={shownName(r)} url={r.pictureUrl} size={38} />
              <div className="main">
                <div className="name" style={{ fontSize: 14 }}>{shownName(r)}</div>
                <div className="sub">{r.alias ? r.displayName : r.phoneNumber ?? ""}</div>
              </div>
              <span
                title="Renombrar en Crona"
                style={{ color: "var(--text2)", display: "flex", padding: 6 }}
                onClick={(e) => {
                  e.stopPropagation();
                  rename(r);
                }}
              >
                <IconPencil size={15} />
              </span>
              <span style={{ color: on ? "var(--accent)" : "var(--text2)", display: "flex" }}>{on ? <IconCheckCircle size={20} /> : <IconCircle size={20} />}</span>
            </button>
          );
        })}
        {loading && <div className="empty">Cargando contactos…</div>}
      </div>
      </>
      )}
    </Sheet>
  );
}


// Editor de lista: nombre + contactos con checkbox (búsqueda propia)
function ListEditor({ instanceId, onSaved, onCancel }: { instanceId: string; onSaved: () => void; onCancel: () => void }) {
  const { toast } = useApp();
  const [name, setName] = useState("");
  const [search, setSearch] = useState("");
  const [items, setItems] = useState<Recipient[]>([]);
  const [members, setMembers] = useState<Recipient[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let alive = true;
    const t = setTimeout(async () => {
      try {
        const all = await fetchAll<Recipient>(`/instances/${instanceId}/recipients`, { kind: "CONTACT", ...(search ? { search } : {}) });
        if (alive) setItems(all);
      } catch {
        /* */
      }
    }, 250);
    return () => {
      alive = false;
      clearTimeout(t);
    };
  }, [search, instanceId]);

  const toggle = (r: Recipient) =>
    setMembers((prev) => (prev.some((x) => x.jid === r.jid) ? prev.filter((x) => x.jid !== r.jid) : [...prev, r]));

  const save = async () => {
    setBusy(true);
    try {
      await api("POST", "/lists", {
        instanceId,
        name: name.trim(),
        members: members.map((m) => ({ jid: m.jid, name: shownName(m), pictureUrl: m.pictureUrl, kind: m.kind })),
      });
      onSaved();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al crear la lista");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={{ padding: "10px 14px", borderBottom: "1px solid var(--border)", display: "flex", flexDirection: "column", gap: 8 }}>
      <input className="field" placeholder="Nombre de la lista (ej. Familia)" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
      <input className="field" placeholder="Buscar contactos" value={search} onChange={(e) => setSearch(e.target.value)} />
      <div style={{ maxHeight: 220, overflowY: "auto", border: "1px solid var(--border)", borderRadius: 10 }}>
        {items.map((r) => {
          const on = members.some((x) => x.jid === r.jid);
          return (
            <button key={r.jid} className="row" onClick={() => toggle(r)} style={{ padding: "8px 10px" }}>
              <Avatar name={shownName(r)} url={r.pictureUrl} size={30} />
              <div className="main"><div className="name" style={{ fontSize: 13 }}>{shownName(r)}</div></div>
              <span style={{ color: on ? "var(--accent)" : "var(--text2)", display: "flex" }}>{on ? <IconCheckCircle size={18} /> : <IconCircle size={18} />}</span>
            </button>
          );
        })}
      </div>
      <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
        <button className="btn small secondary" onClick={onCancel}>Cancelar</button>
        <button className="btn small" disabled={!name.trim() || members.length === 0 || busy} onClick={save}>
          Guardar ({members.length})
        </button>
      </div>
    </div>
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
