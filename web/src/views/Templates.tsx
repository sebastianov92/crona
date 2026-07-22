// Plantillas de mensajes (con soporte de varias partes / split).
import { useCallback, useEffect, useState } from "react";
import { api, ApiError } from "../api";
import { useApp } from "../App";
import { Sheet, Toggle } from "../lib";
import { PartsEditor, newPart, packParts, partsFromTemplate } from "../parts";
import type { PartDraft } from "../parts";
import type { Template, TemplateKind } from "../types";
import { IconGlobe, IconLayers, IconPencil, IconPlus, IconTrash } from "../icons";

const kindTitle: Record<TemplateKind, string> = {
  MESSAGE: "Plantillas de mensajes",
  GROUP_INITIAL: "Plantillas de mensaje inicial",
};

export function useTemplates(kind: TemplateKind) {
  const [items, setItems] = useState<Template[]>([]);
  const [loading, setLoading] = useState(true);
  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const r = await api<{ items: Template[] }>("GET", `/templates?kind=${kind}`);
      setItems(r.items);
    } catch {
      /* */
    } finally {
      setLoading(false);
    }
  }, [kind]);
  useEffect(() => {
    reload();
  }, [reload]);
  return { items, loading, reload };
}

function TemplateRow({ t, onPick, right }: { t: Template; onPick?: () => void; right?: React.ReactNode }) {
  const preview = t.parts.map((p) => p.body).join(" · ");
  return (
    <div className="row" style={{ cursor: onPick ? "pointer" : "default" }}>
      <button className="main" style={{ textAlign: "left" }} onClick={onPick} disabled={!onPick}>
        <div className="name" style={{ fontSize: 14, display: "flex", alignItems: "center", gap: 6 }}>
          {t.name}
          {t.parts.length > 1 && (
            <span className="badge" title={`${t.parts.length} mensajes`} style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
              <IconLayers size={11} /> {t.parts.length}
            </span>
          )}
          {t.isPublic && <span style={{ color: "var(--text2)", display: "inline-flex" }} title="Pública"><IconGlobe size={13} /></span>}
        </div>
        <div className="sub">{preview || "Sin texto"}</div>
      </button>
      {right}
    </div>
  );
}

export function TemplatesSheet({ kind, onClose }: { kind: TemplateKind; onClose: () => void }) {
  const { user, toast } = useApp();
  const { items, loading, reload } = useTemplates(kind);
  const [editing, setEditing] = useState<Template | "new" | null>(null);

  const mine = items.filter((t) => t.ownerId === user.id);
  const others = items.filter((t) => t.ownerId !== user.id);

  const remove = async (t: Template) => {
    if (!confirm(`¿Eliminar la plantilla "${t.name}"?`)) return;
    try {
      await api("DELETE", `/templates/${t.id}`);
      reload();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al eliminar");
    }
  };

  return (
    <Sheet
      title={kindTitle[kind]}
      onClose={onClose}
      actions={<button className="btn small" onClick={() => setEditing("new")}><IconPlus size={16} /></button>}
    >
      <label className="label">Mis plantillas</label>
      <div className="card">
        {!loading && mine.length === 0 && <div className="empty">Todavía no tienes plantillas. Toca + para crear una.</div>}
        {mine.map((t) => (
          <TemplateRow
            key={t.id}
            t={t}
            right={
              <>
                <button className="btn small secondary" title="Editar" onClick={() => setEditing(t)}><IconPencil size={14} /></button>
                <button className="btn small danger" title="Eliminar" onClick={() => remove(t)}><IconTrash size={14} /></button>
              </>
            }
          />
        ))}
      </div>

      <label className="label">Públicas</label>
      <div className="card">
        {others.length === 0 && <div className="empty">No hay plantillas públicas de otros usuarios.</div>}
        {others.map((t) => (
          <TemplateRow
            key={t.id}
            t={t}
            right={
              <>
                <span className="badge">{t.ownerName ?? "Otro usuario"}</span>
                {user.role === "ADMIN" && (
                  <button className="btn small danger" title="Eliminar" onClick={() => remove(t)}><IconTrash size={14} /></button>
                )}
              </>
            }
          />
        ))}
      </div>

      {editing && (
        <TemplateEditor
          kind={kind}
          template={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            reload();
          }}
        />
      )}
    </Sheet>
  );
}

function TemplateEditor({
  kind,
  template,
  onClose,
  onSaved,
}: {
  kind: TemplateKind;
  template: Template | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const { toast } = useApp();
  const [name, setName] = useState(template?.name ?? "");
  const [isPublic, setIsPublic] = useState(template?.isPublic ?? false);
  const [parts, setParts] = useState<PartDraft[]>(template ? partsFromTemplate(template.parts) : [newPart()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const packed = packParts(parts);

  const save = async () => {
    setBusy(true);
    setError("");
    try {
      if (template) await api("PATCH", `/templates/${template.id}`, { name: name.trim(), isPublic, parts: packed });
      else await api("POST", "/templates", { name: name.trim(), kind, isPublic, parts: packed });
      toast("Plantilla guardada ✓");
      onSaved();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Error al guardar la plantilla.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title={template ? "Editar plantilla" : "Nueva plantilla"} onClose={onClose}>
      <label className="label">Nombre</label>
      <input className="field" placeholder="ej. Saludo de bienvenida" value={name} onChange={(e) => setName(e.target.value)} autoFocus />

      <label className="label">Mensaje</label>
      <PartsEditor parts={parts} onChange={setParts} />

      <div className="kv" style={{ marginTop: 12 }}>
        <span>
          Pública
          <div className="hint">Otros usuarios podrán usarla, pero solo tú puedes editarla.</div>
        </span>
        <Toggle on={isPublic} onChange={setIsPublic} />
      </div>

      {error && <div className="error">{error}</div>}
      <button className="btn" style={{ marginTop: 16 }} disabled={busy || !name.trim() || packed.length === 0} onClick={save}>
        {busy ? <span className="spin" /> : "Guardar"}
      </button>
    </Sheet>
  );
}

/** Selector: elige una plantilla y devuelve sus partes (no modifica la plantilla). */
export function TemplatePicker({
  kind,
  onPick,
  onClose,
}: {
  kind: TemplateKind;
  onPick: (parts: PartDraft[]) => void;
  onClose: () => void;
}) {
  const { user } = useApp();
  const { items, loading } = useTemplates(kind);
  const mine = items.filter((t) => t.ownerId === user.id);
  const others = items.filter((t) => t.ownerId !== user.id);

  const pick = (t: Template) => onPick(partsFromTemplate(t.parts));

  return (
    <Sheet title="Usar plantilla" onClose={onClose}>
      {loading && <div className="empty">Cargando plantillas…</div>}
      {!loading && items.length === 0 && (
        <div className="empty">No hay plantillas todavía. Créalas en Ajustes → Plantillas.</div>
      )}
      {mine.length > 0 && (
        <>
          <label className="label">Mis plantillas</label>
          <div className="card">
            {mine.map((t) => (
              <TemplateRow key={t.id} t={t} onPick={() => pick(t)} />
            ))}
          </div>
        </>
      )}
      {others.length > 0 && (
        <>
          <label className="label">Públicas</label>
          <div className="card">
            {others.map((t) => (
              <TemplateRow key={t.id} t={t} onPick={() => pick(t)} right={<span className="badge">{t.ownerName ?? "Otro usuario"}</span>} />
            ))}
          </div>
        </>
      )}
    </Sheet>
  );
}
