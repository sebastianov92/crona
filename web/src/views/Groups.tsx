// Creación de grupos de WhatsApp (ya o programada) con foto, participantes y mensaje inicial.
import { useCallback, useEffect, useState } from "react";
import { api, ApiError, uploadMedia } from "../api";
import { useApp } from "../App";
import { Avatar, MediaImg, Sheet, Toggle } from "../lib";
import { PartsEditor, newPart, packParts } from "../parts";
import type { PartDraft } from "../parts";
import { shownName } from "../types";
import type { GroupJob, GroupJobStatus, Recipient } from "../types";
import { IconCamera, IconPlus, IconTemplate, IconTrash, IconUsersPlus } from "../icons";
import { RecipientPicker } from "./Scheduled";
import { TemplatePicker } from "./Templates";

const groupStatusLabel: Record<GroupJobStatus, string> = {
  PENDING: "Pendiente",
  CREATING: "Creando…",
  DONE: "Creado",
  FAILED: "Fallido",
};

function localInputValue(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

export function GroupsSheet({ onClose }: { onClose: () => void }) {
  const { toast } = useApp();
  const [items, setItems] = useState<GroupJob[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await api<{ items: GroupJob[] }>("GET", "/groups")).items);
    } catch {
      /* */
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  // mientras haya grupos en marcha, refresca solo para ver cuándo pasan a Creado/Fallido
  const working = items.some((g) => g.status === "PENDING" || g.status === "CREATING");
  useEffect(() => {
    if (!working) return;
    const t = setInterval(() => {
      api<{ items: GroupJob[] }>("GET", "/groups")
        .then((r) => setItems(r.items))
        .catch(() => {});
    }, 8000);
    return () => clearInterval(t);
  }, [working]);

  const remove = async (g: GroupJob) => {
    if (!confirm(`¿Eliminar "${g.name}" de la lista? El grupo ya creado en WhatsApp no se borra.`)) return;
    try {
      await api("DELETE", `/groups/${g.id}`);
      reload();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al eliminar");
    }
  };

  return (
    <Sheet
      title="Grupos"
      onClose={onClose}
      actions={<button className="btn small" onClick={() => setCreating(true)}><IconPlus size={16} /></button>}
    >
      <div className="card">
        {loading && <div className="empty">Cargando…</div>}
        {!loading && items.length === 0 && <div className="empty">Todavía no has creado grupos. Toca + para crear el primero.</div>}
        {items.map((g) => (
          <div key={g.id} className="row" style={{ cursor: "default" }}>
            {g.pictureMediaId ? (
              <div className="groupthumb"><MediaImg mediaId={g.pictureMediaId} type="IMAGE" /></div>
            ) : (
              <Avatar name={g.name} url={null} size={44} />
            )}
            <div className="main">
              <div className="name" style={{ fontSize: 14 }}>{g.name}</div>
              <div className="sub">
                {(g.participants ?? []).length} participante{(g.participants ?? []).length !== 1 ? "s" : ""}
                {(g.parts ?? []).length > 1 ? ` · ${g.parts.length} mensajes` : ""}
                {g.runAt ? ` · ${new Date(g.runAt).toLocaleString("es", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })}` : ""}
              </div>
              {g.lastError && <div className="sub" style={{ color: "var(--danger)" }}>{g.lastError}</div>}
            </div>
            <span className={`badge ${g.status === "DONE" ? "green" : ""}`} style={g.status === "FAILED" ? { color: "var(--danger)" } : undefined}>
              {groupStatusLabel[g.status]}
            </span>
            <button className="btn small danger" title="Eliminar" onClick={() => remove(g)}><IconTrash size={15} /></button>
          </div>
        ))}
      </div>
      {creating && (
        <GroupForm
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            reload();
          }}
        />
      )}
    </Sheet>
  );
}

function GroupForm({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const { user, instances, toast } = useApp();
  const [instanceId, setInstanceId] = useState(instances[0]?.id ?? "");
  const [name, setName] = useState("");
  const [picture, setPicture] = useState<File | null>(null);
  const [useDefaultPicture, setUseDefaultPicture] = useState(true);
  const [recipients, setRecipients] = useState<Recipient[]>([]);
  const [showPicker, setShowPicker] = useState(false);
  const [parts, setParts] = useState<PartDraft[]>([newPart()]);
  const [showTemplates, setShowTemplates] = useState(false);
  const [scheduled, setScheduled] = useState(false);
  const [when, setWhen] = useState(() => localInputValue(new Date(Date.now() + 3600_000)));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const defaultPic = user.defaultGroupPictureMediaId;
  // el server exige al menos +1 min si es programado
  const whenMs = new Date(when).getTime();
  const whenOk = !scheduled || (!Number.isNaN(whenMs) && whenMs > Date.now() + 60_000);
  const canSubmit = !!instanceId && !!name.trim() && recipients.length > 0 && whenOk && !busy;

  const submit = async () => {
    setBusy(true);
    setError("");
    try {
      let pictureMediaId: string | null = useDefaultPicture ? defaultPic : null;
      if (picture) pictureMediaId = (await uploadMedia(picture)).mediaId;
      await api("POST", "/groups", {
        instanceId,
        name: name.trim(),
        pictureMediaId,
        participants: recipients.map((r) => ({ jid: r.jid, name: shownName(r) })),
        parts: packParts(parts).slice(0, 10),
        scheduledAt: scheduled ? new Date(when).toISOString() : null,
      });
      toast(scheduled ? "Grupo programado ✓" : "Creando el grupo…");
      onCreated();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Error al crear el grupo.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title="Nuevo grupo" onClose={onClose}>
      {instances.length > 1 && (
        <>
          <label className="label">Crear desde</label>
          <select className="field" value={instanceId} onChange={(e) => setInstanceId(e.target.value)}>
            {instances.map((i) => (
              <option key={i.id} value={i.id}>{i.name}</option>
            ))}
          </select>
        </>
      )}

      <label className="label">Nombre del grupo</label>
      <input className="field" placeholder="ej. Equipo de ventas" value={name} onChange={(e) => setName(e.target.value)} autoFocus />

      <label className="label">Foto del grupo</label>
      {picture ? (
        <div className="kv">
          <span style={{ display: "flex", alignItems: "center", gap: 6 }}><IconCamera size={14} /> {picture.name}</span>
          <button className="btn small secondary" onClick={() => setPicture(null)}>Quitar</button>
        </div>
      ) : useDefaultPicture && defaultPic ? (
        <div className="kv">
          <span style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <span className="groupthumb"><MediaImg mediaId={defaultPic} type="IMAGE" /></span>
            Foto por defecto
          </span>
          <button className="btn small secondary" onClick={() => setUseDefaultPicture(false)}>Quitar</button>
        </div>
      ) : (
        <div style={{ display: "flex", gap: 8 }}>
          <label className="filebtn">
            <IconCamera size={16} />
            Elegir foto
            <input type="file" hidden accept="image/jpeg,image/png,image/webp" onChange={(e) => setPicture(e.target.files?.[0] ?? null)} />
          </label>
          {defaultPic && !useDefaultPicture && (
            <button className="btn small secondary" onClick={() => setUseDefaultPicture(true)}>Usar la de por defecto</button>
          )}
        </div>
      )}

      <label className="label">Participantes</label>
      <div className="card">
        {recipients.map((r) => (
          <div key={r.jid} className="row" style={{ cursor: "default" }}>
            <Avatar name={shownName(r)} url={r.pictureUrl} size={34} />
            <div className="main"><div className="name" style={{ fontSize: 14 }}>{shownName(r)}</div></div>
            <button className="btn small secondary" onClick={() => setRecipients(recipients.filter((x) => x.jid !== r.jid))}>✕</button>
          </div>
        ))}
        <button className="row" onClick={() => setShowPicker(true)}>
          <div className="main" style={{ color: "var(--accent)", display: "flex", alignItems: "center", gap: 6 }}>
            <IconPlus size={15} /> {recipients.length ? "Agregar más" : "Elegir participantes"}
          </div>
        </button>
      </div>

      <div className="labelrow">
        <label className="label" style={{ margin: 0 }}>Mensaje inicial (opcional)</label>
        <button className="btn small secondary" onClick={() => setShowTemplates(true)}>
          <IconTemplate size={14} /> Usar plantilla
        </button>
      </div>
      <PartsEditor parts={parts} onChange={setParts} placeholder="Mensaje de bienvenida al grupo" />
      <div className="hint">Se envía entre 5 y 10 segundos después de crear el grupo.</div>

      <div className="kv" style={{ marginTop: 12 }}>
        <span>
          Programar para después
          <div className="hint">Apagado: el grupo se crea ahora mismo.</div>
        </span>
        <Toggle on={scheduled} onChange={setScheduled} />
      </div>
      {scheduled && (
        <>
          <input className="field" type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} />
          {!whenOk && <div className="hint">La fecha debe ser al menos 1 minuto en el futuro.</div>}
        </>
      )}

      {error && <div className="error">{error}</div>}
      <button className="btn" style={{ marginTop: 16 }} disabled={!canSubmit} onClick={submit}>
        {busy ? <span className="spin" /> : scheduled ? "Programar grupo" : "Crear grupo"}
      </button>

      {showPicker && (
        <RecipientPicker
          instanceId={instanceId}
          onlyContacts
          onDone={(picked) => {
            const contacts = picked.filter((p) => p.kind === "CONTACT");
            if (contacts.length < picked.length) toast("Solo se pueden agregar contactos como participantes.");
            setRecipients((prev) => [...prev, ...contacts.filter((p) => !prev.some((x) => x.jid === p.jid))]);
            setShowPicker(false);
          }}
          onClose={() => setShowPicker(false)}
        />
      )}
      {showTemplates && (
        <TemplatePicker
          kind="GROUP_INITIAL"
          onPick={(p) => {
            setParts(p);
            setShowTemplates(false);
          }}
          onClose={() => setShowTemplates(false)}
        />
      )}
    </Sheet>
  );
}

/** Botón de entrada desde la vista Chats. */
export function GroupsButton() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button className="btn small secondary" onClick={() => setOpen(true)}>
        <IconUsersPlus size={16} /> Crear grupo
      </button>
      {open && <GroupsSheet onClose={() => setOpen(false)} />}
    </>
  );
}
