import { useEffect, useState } from "react";
import { api, ApiError, uploadMedia } from "../api";
import { useApp, useTheme } from "../App";
import { Avatar, DayDots, MediaImg, Sheet, Toggle, dayNames, useAsync } from "../lib";
import type { AdminSettings, AutoReply, Instance, Paginated, User } from "../types";
import { IconCamera, IconCheckCircle, IconChevron, IconPause, IconPencil, IconPlay, IconPlus, IconTrash } from "../icons";
import { TemplatesSheet } from "./Templates";

export default function Settings() {
  const { user, setUser, instances, upcoming, refreshMessages, logout, toast } = useApp();
  const [theme, setTheme] = useTheme();
  const [view, setView] = useState<
    "" | "instances" | "autoreplies" | "ntfy" | "admin" | "users" | "templates" | "grouptemplates" | "grouppicture"
  >("");

  const anyActive = upcoming.some((m) => m.status === "ACTIVE");
  const anyPaused = upcoming.some((m) => m.status === "PAUSED");

  const pauseAll = async (paused: boolean) => {
    try {
      await api("POST", "/messages/pause-all", { paused });
      await refreshMessages();
      toast(paused ? "Todos los envíos pausados" : "Envíos reanudados");
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error");
    }
  };

  return (
    <div className="page">
      <h1 className="pagetitle">Ajustes</h1>

      <label className="label">Cuenta</label>
      <div className="card" style={{ padding: 14 }}>
        <div className="kv"><span className="k">Nombre</span><span>{user.name}</span></div>
        <div className="kv"><span className="k">Email</span><span>{user.email}</span></div>
        <div className="kv"><span className="k">Rol</span><span>{user.role === "ADMIN" ? "Administrador" : "Usuario"}</span></div>
      </div>

      <label className="label">Apariencia</label>
      <div className="seg">
        {(["system", "light", "dark"] as const).map((t) => (
          <button key={t} className={theme === t ? "active" : ""} onClick={() => setTheme(t)}>
            {t === "system" ? "Sistema" : t === "light" ? "Claro" : "Oscuro"}
          </button>
        ))}
      </div>

      <label className="label">WhatsApp</label>
      <div className="card">
        <button className="row" onClick={() => setView("instances")}>
          <div className="main">Conectar a WhatsApp ({instances.length})</div><IconChevron size={16} />
        </button>
        <button className="row" onClick={() => setView("autoreplies")}>
          <div className="main">Respuestas automáticas</div><IconChevron size={16} />
        </button>
      </div>

      <label className="label">Plantillas</label>
      <div className="card">
        <button className="row" onClick={() => setView("templates")}>
          <div className="main">Plantillas de mensajes</div><IconChevron size={16} />
        </button>
      </div>

      <label className="label">Grupos</label>
      <div className="card">
        <button className="row" onClick={() => setView("grouppicture")}>
          <div className="main">Foto por defecto de los grupos</div>
          {user.defaultGroupPictureMediaId && <span className="badge green">Configurada</span>}
          <IconChevron size={16} />
        </button>
        <button className="row" onClick={() => setView("grouptemplates")}>
          <div className="main">Plantillas de mensaje inicial</div><IconChevron size={16} />
        </button>
      </div>

      <label className="label">Chats</label>
      <div className="card" style={{ padding: "2px 14px" }}>
        <div className="kv">
          <span className="k">Chats en la lista</span>
          <select
            className="field"
            style={{ width: "auto", padding: "6px 10px" }}
            value={user.chatListCount}
            onChange={async (e) => {
              try {
                setUser(await api<User>("PATCH", "/me", { chatListCount: Number(e.target.value) }));
              } catch { toast("Error al guardar"); }
            }}
          >
            {[5, 10, 20, 30, 50, 75, 100].map((n) => <option key={n} value={n}>{n}</option>)}
          </select>
        </div>
        <div className="kv">
          <span className="k">Mensajes recibidos por chat</span>
          <select
            className="field"
            style={{ width: "auto", padding: "6px 10px" }}
            value={user.chatIncomingCount}
            onChange={async (e) => {
              try {
                setUser(await api<User>("PATCH", "/me", { chatIncomingCount: Number(e.target.value) }));
              } catch { toast("Error al guardar"); }
            }}
          >
            <option value={0}>Ninguno</option>
            <option value={1}>El último</option>
            <option value={5}>Últimos 5</option>
            <option value={10}>Últimos 10</option>
            <option value={20}>Últimos 20</option>
          </select>
        </div>
      </div>

      <label className="label">Horarios rápidos (Mañana · Tarde · Noche)</label>
      <div className="card" style={{ padding: "2px 14px" }}>
        <QuickHoursEditor />
      </div>

      <label className="label">Envíos</label>
      <div className="card">
        {anyActive && (
          <button className="row" onClick={() => pauseAll(true)}><div className="main" style={{ display: "flex", alignItems: "center", gap: 8 }}><IconPause size={16} /> Pausar todos los envíos</div></button>
        )}
        {!anyActive && anyPaused && (
          <button className="row" onClick={() => pauseAll(false)}><div className="main" style={{ display: "flex", alignItems: "center", gap: 8 }}><IconPlay size={16} /> Reanudar todos los envíos</div></button>
        )}
        {!anyActive && !anyPaused && <div className="row" style={{ cursor: "default", color: "var(--text2)" }}>Sin mensajes pendientes.</div>}
      </div>

      <label className="label">Notificaciones</label>
      <div className="card">
        <button className="row" onClick={() => setView("ntfy")}><div className="main">Notificaciones (ntfy)</div><IconChevron size={16} /></button>
      </div>

      {user.role === "ADMIN" && (
        <>
          <label className="label">Administración</label>
          <div className="card">
            <button className="row" onClick={() => setView("admin")}><div className="main">Servidor Evolution</div><IconChevron size={16} /></button>
            <button className="row" onClick={() => setView("users")}><div className="main">Usuarios e invitaciones</div><IconChevron size={16} /></button>
          </div>
        </>
      )}

      <button className="btn danger" style={{ marginTop: 24 }} onClick={logout}>Cerrar sesión</button>

      {view === "instances" && <InstancesSheet onClose={() => setView("")} />}
      {view === "autoreplies" && <AutoRepliesSheet onClose={() => setView("")} />}
      {view === "ntfy" && <NtfySheet onClose={() => setView("")} />}
      {view === "admin" && <AdminSheet onClose={() => setView("")} />}
      {view === "users" && <UsersSheet onClose={() => setView("")} />}
      {view === "templates" && <TemplatesSheet kind="MESSAGE" onClose={() => setView("")} />}
      {view === "grouptemplates" && <TemplatesSheet kind="GROUP_INITIAL" onClose={() => setView("")} />}
      {view === "grouppicture" && <GroupPictureSheet onClose={() => setView("")} />}
    </div>
  );
}

// ── Foto por defecto de los grupos ───────────────────────

function GroupPictureSheet({ onClose }: { onClose: () => void }) {
  const { user, setUser, toast } = useApp();
  const [busy, setBusy] = useState(false);

  const save = async (mediaId: string | null) => {
    setBusy(true);
    try {
      setUser(await api<User>("PATCH", "/me", { defaultGroupPictureMediaId: mediaId }));
      toast(mediaId ? "Foto guardada ✓" : "Foto quitada");
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al guardar");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title="Foto por defecto de los grupos" onClose={onClose}>
      <p className="hint" style={{ marginBottom: 12 }}>
        Se usa al crear grupos nuevos. Puedes cambiarla en cada grupo.
      </p>
      {user.defaultGroupPictureMediaId && (
        <div style={{ marginBottom: 12 }}>
          <MediaImg mediaId={user.defaultGroupPictureMediaId} type="IMAGE" />
        </div>
      )}
      <label className="filebtn">
        <IconCamera size={16} />
        {user.defaultGroupPictureMediaId ? "Cambiar foto" : "Elegir foto"}
        <input
          type="file"
          hidden
          accept="image/jpeg,image/png,image/webp"
          disabled={busy}
          onChange={async (e) => {
            const f = e.target.files?.[0];
            if (!f) return;
            setBusy(true);
            try {
              const { mediaId } = await uploadMedia(f);
              await save(mediaId);
            } catch (err) {
              toast(err instanceof ApiError ? err.message : "Error al subir la foto");
              setBusy(false);
            }
          }}
        />
      </label>
      {user.defaultGroupPictureMediaId && (
        <button className="btn secondary" style={{ marginTop: 10 }} disabled={busy} onClick={() => save(null)}>
          Quitar foto
        </button>
      )}
    </Sheet>
  );
}

// ── Horarios rápidos ─────────────────────────────────────

const toHHMM = (min: number) => `${String(Math.floor(min / 60)).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;
const toMin = (hhmm: string) => {
  const [h, m] = hhmm.split(":").map(Number);
  return (h || 0) * 60 + (m || 0);
};

function QuickHoursEditor() {
  const { user, setUser, toast } = useApp();
  const periods = [
    ["morning", "Mañana"],
    ["afternoon", "Tarde"],
    ["evening", "Noche"],
  ] as const;

  const save = async (key: (typeof periods)[number][0], start: number, end: number) => {
    try {
      setUser(await api<User>("PATCH", "/me", { quickHours: { ...user.quickHours, [key]: { start, end } } }));
    } catch {
      toast("Error al guardar el horario");
    }
  };

  return (
    <>
      {periods.map(([key, label]) => {
        const r = user.quickHours[key];
        const exact = r.start === r.end;
        return (
          <div key={key} className="kv" style={{ flexWrap: "wrap", gap: 8 }}>
            <span className="k">{label}</span>
            <span style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap" }}>
              <select
                className="field"
                style={{ width: "auto", padding: "6px 8px" }}
                value={exact ? "exact" : "range"}
                onChange={(e) =>
                  e.target.value === "exact" ? save(key, r.start, r.start) : save(key, r.start, Math.min(r.start + 60, 1439))
                }
              >
                <option value="exact">Hora exacta</option>
                <option value="range">Rango</option>
              </select>
              <input
                className="field"
                style={{ width: "auto", padding: "6px 8px" }}
                type="time"
                value={toHHMM(r.start)}
                onChange={(e) => {
                  const s = toMin(e.target.value);
                  save(key, s, exact ? s : Math.max(s, r.end));
                }}
              />
              {!exact && (
                <>
                  <span className="k">a</span>
                  <input
                    className="field"
                    style={{ width: "auto", padding: "6px 8px" }}
                    type="time"
                    value={toHHMM(r.end)}
                    onChange={(e) => save(key, Math.min(r.start, toMin(e.target.value)), toMin(e.target.value))}
                  />
                </>
              )}
            </span>
            <div className="hint" style={{ width: "100%", marginTop: 0 }}>
              {exact ? "Se envía entre 1 y 5 min después de esa hora." : "Se envía a una hora aleatoria dentro del rango."}
            </div>
          </div>
        );
      })}
    </>
  );
}

// ── Instancias + vinculación ─────────────────────────────

function InstancesSheet({ onClose }: { onClose: () => void }) {
  const { instances, refreshInstances, toast } = useApp();
  const [linking, setLinking] = useState(false);

  const rename = async (i: Instance) => {
    const name = window.prompt("Nuevo nombre para la instancia:", i.name);
    if (!name || !name.trim() || name.trim() === i.name) return;
    try {
      await api("PATCH", `/instances/${i.id}`, { name: name.trim() });
      await refreshInstances();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al renombrar");
    }
  };

  // subir una posición: el orden manda — la primera de la lista es la principal
  const moveUp = async (i: Instance) => {
    const ids = instances.map((x) => x.id);
    const idx = ids.indexOf(i.id);
    if (idx <= 0) return;
    [ids[idx - 1], ids[idx]] = [ids[idx], ids[idx - 1]];
    try {
      await api("PUT", "/instances/order", { ids });
      await refreshInstances();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al reordenar");
    }
  };

  return (
    <Sheet title="Conectar a WhatsApp" onClose={onClose} actions={<button className="btn small" onClick={() => setLinking(true)}><IconPlus size={14} /> Vincular</button>}>
      {instances.length > 1 && (
        <div className="hint" style={{ marginBottom: 8 }}>La primera instancia es la principal: sale por defecto al programar. Usa ↑ para reordenar.</div>
      )}
      <div className="card">
        {instances.length === 0 && <div className="empty">Vincula tu número de WhatsApp para empezar.</div>}
        {instances.map((i, idx) => {
          const primary = idx === 0 && instances.length > 1;
          return (
          <div key={i.id} className="row" style={{ cursor: "default" }}>
            <Avatar name={i.name} url={i.profilePicUrl} />
            <div className="main">
              <div className="name" style={{ display: "flex", alignItems: "center", gap: 5 }}>
                {i.name}
                {primary && <span title="Instancia principal" style={{ color: "#f5b301" }}>★</span>}
              </div>
              <div className="sub">{i.phoneNumber ?? "—"}{primary ? " · principal" : ""}</div>
            </div>
            <span className={`badge ${i.status === "CONNECTED" ? "green" : ""}`}>
              {i.status === "CONNECTED" ? "Conectado" : i.status === "CONNECTING" ? "Conectando…" : "Desconectado"}
            </span>
            {idx > 0 && (
              <button className="btn small secondary" title="Subir (la primera es la principal)" onClick={() => moveUp(i)}>↑</button>
            )}
            <button className="btn small secondary" title="Renombrar" onClick={() => rename(i)}>
              <IconPencil size={14} />
            </button>
            <button
              className="btn small danger"
              onClick={async () => {
                if (!confirm(`¿Eliminar ${i.name}? Se desconecta el número y se borran sus mensajes.`)) return;
                try {
                  await api("DELETE", `/instances/${i.id}`);
                  await refreshInstances();
                } catch (e) {
                  toast(e instanceof ApiError ? e.message : "Error");
                }
              }}
            >
              <IconTrash size={15} />
            </button>
          </div>
          );
        })}
      </div>
      {linking && <LinkWizard onClose={() => setLinking(false)} />}
    </Sheet>
  );
}

function LinkWizard({ onClose }: { onClose: () => void }) {
  const { instances, refreshInstances } = useApp();
  const [number, setNumber] = useState("");
  const [instance, setInstance] = useState<Instance | null>(null);
  const [pairing, setPairing] = useState<string | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [showQr, setShowQr] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    if (!instance || connected) return;
    const t = setInterval(async () => {
      try {
        const s = await api<Instance>("GET", `/instances/${instance.id}/status`);
        if (s.status === "CONNECTED") {
          setConnected(true);
          refreshInstances();
        }
      } catch {
        /* */
      }
    }, 4000);
    return () => clearInterval(t);
  }, [instance, connected, refreshInstances]);

  const create = async () => {
    setBusy(true);
    setError("");
    try {
      const name = instances.some((i) => i.name === "Personal") ? `Personal ${instances.length + 1}` : "Personal";
      const clean = number.replace(/\D/g, "");
      const r = await api<{ instance: Instance; qrBase64: string | null; pairingCode: string | null }>("POST", "/instances", {
        name,
        phoneNumber: clean || undefined,
      });
      setInstance(r.instance);
      setQr(r.qrBase64);
      setPairing(r.pairingCode);
      if (!r.pairingCode && clean) {
        const q = await api<{ qrBase64: string | null; pairingCode: string | null }>("GET", `/instances/${r.instance.id}/qr?number=${clean}`);
        setPairing(q.pairingCode ?? null);
        if (q.qrBase64) setQr(q.qrBase64);
      }
      await refreshInstances();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Error al crear la instancia.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title={connected ? "¡Vinculado!" : "Vincular número"} onClose={onClose}>
      {connected ? (
        <div className="center" style={{ minHeight: 200 }}>
          <div style={{ color: "var(--accent)" }}><IconCheckCircle size={72} /></div>
          <p>WhatsApp vinculado. Ya puedes programar mensajes.</p>
          <button className="btn" style={{ marginTop: 14 }} onClick={onClose}>Listo</button>
        </div>
      ) : !instance ? (
        <>
          <p className="hint" style={{ marginBottom: 10 }}>El mismo número que usas en WhatsApp, con código de país y sin +.</p>
          <input className="field" placeholder="593999999999" inputMode="numeric" value={number} onChange={(e) => setNumber(e.target.value)} />
          {error && <div className="error">{error}</div>}
          <button className="btn" style={{ marginTop: 14 }} disabled={busy || number.replace(/\D/g, "").length < 8} onClick={create}>
            {busy ? <span className="spin" /> : "Continuar"}
          </button>
        </>
      ) : showQr && qr ? (
        <>
          <img src={qr} style={{ width: 240, margin: "0 auto", display: "block", borderRadius: 12, background: "#fff", padding: 8 }} />
          <p className="hint" style={{ textAlign: "center", marginTop: 10 }}>WhatsApp → Dispositivos vinculados → Vincular dispositivo → escanea.</p>
          <button className="btn ghost" style={{ margin: "8px auto 0", display: "block" }} onClick={() => setShowQr(false)}>Volver al código</button>
        </>
      ) : (
        <>
          <div className="code">{pairing ? `${pairing.slice(0, 4)} - ${pairing.slice(4)}` : "········"}</div>
          <ol style={{ margin: "14px 0 0 20px", color: "var(--text2)", fontSize: 14, lineHeight: 1.8 }}>
            <li>Abre WhatsApp → Configuración</li>
            <li>Dispositivos vinculados → Vincular dispositivo</li>
            <li>"Vincular con el número de teléfono"</li>
            <li>Escribe el código de 8 dígitos</li>
          </ol>
          <div style={{ display: "flex", gap: 8, marginTop: 14 }}>
            {qr && <button className="btn secondary" onClick={() => setShowQr(true)}>Ver QR</button>}
            <button
              className="btn secondary"
              disabled={busy}
              onClick={async () => {
                setBusy(true);
                const clean = number.replace(/\D/g, "");
                const q = await api<{ pairingCode: string | null; qrBase64: string | null }>("GET", `/instances/${instance.id}/qr?number=${clean}`).catch(() => null);
                if (q?.pairingCode) setPairing(q.pairingCode);
                if (q?.qrBase64) setQr(q.qrBase64);
                setBusy(false);
              }}
            >
              Nuevo código
            </button>
          </div>
        </>
      )}
    </Sheet>
  );
}

// ── Respuestas automáticas ───────────────────────────────

function AutoRepliesSheet({ onClose }: { onClose: () => void }) {
  const [rules, , reload] = useAsync(() => api<Paginated<AutoReply>>("GET", "/autoreplies"), []);
  const [editing, setEditing] = useState<AutoReply | null | "new">(null);
  const { instances, toast } = useApp();

  return (
    <Sheet title="Respuestas automáticas" onClose={onClose} actions={<button className="btn small" onClick={() => setEditing("new")}><IconPlus size={16} /></button>}>
      <div className="card">
        {(rules?.items ?? []).length === 0 && <div className="empty">Sin reglas. Crea una para responder solo o recibir avisos.</div>}
        {(rules?.items ?? []).map((r) => (
          <div key={r.id} className="row" style={{ cursor: "default" }}>
            <button className="main" style={{ textAlign: "left" }} onClick={() => setEditing(r)}>
              <div className="name" style={{ fontSize: 14 }}>
                {r.contactName ? `Si ${r.contactName}` : "Si alguien"} {r.keyword ? `dice "${r.keyword}"` : "escribe"}
              </div>
              <div className="sub">{r.action === "REPLY" ? `Responder: ${r.replyText}` : "Avisarme por ntfy"}</div>
              {(r.activeFromHour !== null || r.activeDays.length > 0) && (
                <div className="sub">
                  {r.activeFromHour !== null && `${r.activeFromHour}:00–${r.activeToHour}:00 `}
                  {r.activeDays.length > 0 && r.activeDays.map((d) => dayNames[d]).join("")}
                </div>
              )}
            </button>
            <Toggle
              on={r.enabled}
              onChange={async (v) => {
                await api("PATCH", `/autoreplies/${r.id}`, { enabled: v }).catch(() => toast("Error"));
                reload();
              }}
            />
            <button
              className="btn small danger"
              onClick={async () => {
                if (!confirm("¿Eliminar esta regla?")) return;
                await api("DELETE", `/autoreplies/${r.id}`).catch(() => toast("Error"));
                reload();
              }}
            >
              <IconTrash size={15} />
            </button>
          </div>
        ))}
      </div>
      <p className="hint" style={{ marginTop: 10 }}>Las respuestas salen con retraso aleatorio de 1–5 min y máx. 1 vez por contacto por ventana.</p>
      {editing && (
        <AutoReplyEdit
          rule={editing === "new" ? null : editing}
          instances={instances}
          onClose={() => {
            setEditing(null);
            reload();
          }}
        />
      )}
    </Sheet>
  );
}

function AutoReplyEdit({ rule, instances, onClose }: { rule: AutoReply | null; instances: Instance[]; onClose: () => void }) {
  const { toast } = useApp();
  const [instanceId, setInstanceId] = useState(rule?.instanceId ?? instances[0]?.id ?? "");
  const [action, setAction] = useState(rule?.action ?? "REPLY");
  const [keyword, setKeyword] = useState(rule?.keyword ?? "");
  const [replyText, setReplyText] = useState(rule?.replyText ?? "");
  const [limitHours, setLimitHours] = useState(rule?.activeFromHour != null);
  const [fromHour, setFromHour] = useState(rule?.activeFromHour ?? 22);
  const [toHour, setToHour] = useState(rule?.activeToHour ?? 7);
  const [days, setDays] = useState<Set<number>>(new Set(rule?.activeDays ?? []));
  const [cooldown, setCooldown] = useState(rule?.cooldownMinutes ?? 60);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const save = async () => {
    setBusy(true);
    setError("");
    try {
      const body = {
        instanceId,
        action,
        keyword: keyword.trim() || null,
        replyText: action === "REPLY" ? replyText : null,
        activeFromHour: limitHours ? fromHour : null,
        activeToHour: limitHours ? toHour : null,
        activeDays: [...days].sort(),
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        cooldownMinutes: cooldown,
        enabled: rule?.enabled ?? true,
      };
      if (rule) await api("PATCH", `/autoreplies/${rule.id}`, body);
      else await api("POST", "/autoreplies", body);
      toast("Regla guardada ✓");
      onClose();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Error al guardar.");
    } finally {
      setBusy(false);
    }
  };

  const HOURS = Array.from({ length: 24 }, (_, i) => i);

  return (
    <Sheet title={rule ? "Editar regla" : "Nueva regla"} onClose={onClose}>
      {instances.length > 1 && !rule && (
        <>
          <label className="label">Número que responde</label>
          <select className="field" value={instanceId} onChange={(e) => setInstanceId(e.target.value)}>
            {instances.map((i) => (
              <option key={i.id} value={i.id}>{i.name}</option>
            ))}
          </select>
        </>
      )}
      <label className="label">Palabra clave</label>
      <input className="field" placeholder="ej. precio, cita, hola…" value={keyword} onChange={(e) => setKeyword(e.target.value)} />
      <div className="hint">Deja vacío para cualquier mensaje.</div>

      <label className="label">Acción</label>
      <div className="seg">
        <button className={action === "REPLY" ? "active" : ""} onClick={() => setAction("REPLY")}>Responder</button>
        <button className={action === "NOTIFY" ? "active" : ""} onClick={() => setAction("NOTIFY")}>Avisarme (ntfy)</button>
      </div>
      {action === "REPLY" && (
        <>
          <textarea className="field" style={{ marginTop: 10 }} placeholder="Texto de respuesta" value={replyText} onChange={(e) => setReplyText(e.target.value)} />
          <div className="hint">Variables: {"{nombre}"} · {"{primer_nombre}"} · {"{fecha}"} · {"{dia}"}</div>
        </>
      )}

      <div className="kv" style={{ marginTop: 12 }}>
        <span>Solo en cierto horario</span>
        <Toggle on={limitHours} onChange={setLimitHours} />
      </div>
      {limitHours && (
        <div style={{ display: "flex", gap: 8 }}>
          <select className="field" value={fromHour} onChange={(e) => setFromHour(+e.target.value)}>
            {HOURS.map((h) => (<option key={h} value={h}>Desde {h}:00</option>))}
          </select>
          <select className="field" value={toHour} onChange={(e) => setToHour(+e.target.value)}>
            {HOURS.map((h) => (<option key={h} value={h}>Hasta {h}:00</option>))}
          </select>
        </div>
      )}
      <label className="label">Días (vacío = todos)</label>
      <DayDots value={days} onChange={setDays} />
      <label className="label">Máx. 1 vez por contacto cada</label>
      <select className="field" value={cooldown} onChange={(e) => setCooldown(+e.target.value)}>
        <option value={15}>15 minutos</option>
        <option value={60}>1 hora</option>
        <option value={240}>4 horas</option>
        <option value={1440}>24 horas</option>
      </select>

      {error && <div className="error">{error}</div>}
      <button className="btn" style={{ marginTop: 16 }} disabled={busy || (action === "REPLY" && !replyText.trim())} onClick={save}>
        {busy ? <span className="spin" /> : "Guardar"}
      </button>
    </Sheet>
  );
}

// ── ntfy ─────────────────────────────────────────────────

function NtfySheet({ onClose }: { onClose: () => void }) {
  const { user, setUser, toast } = useApp();
  const [topic, setTopic] = useState(user.ntfyTopic ?? "");
  const [notifyOnSent, setNotifyOnSent] = useState(user.notifyOnSent);
  const [busy, setBusy] = useState(false);

  const save = async () => {
    setBusy(true);
    try {
      const u = await api<User>("PATCH", "/me", { ntfyTopic: topic || null, notifyOnSent });
      setUser(u);
      toast("Guardado ✓");
      onClose();
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title="Notificaciones (ntfy)" onClose={onClose}>
      <label className="label">Topic</label>
      <input className="field" placeholder="crona-tunombre-a8k2x1" value={topic} onChange={(e) => setTopic(e.target.value)} />
      {!topic && (
        <button className="btn ghost" onClick={() => setTopic(`crona-${user.name.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 10)}-${Math.random().toString(36).slice(2, 8)}`)}>
          Generar topic aleatorio
        </button>
      )}
      <div className="hint">Instala la app ntfy en tu iPhone y suscríbete a este topic. Funciona como secreto.</div>
      <div className="kv" style={{ marginTop: 12 }}>
        <span>Notificar también envíos exitosos</span>
        <Toggle on={notifyOnSent} onChange={setNotifyOnSent} />
      </div>
      <button className="btn" style={{ marginTop: 16 }} disabled={busy} onClick={save}>
        {busy ? <span className="spin" /> : "Guardar"}
      </button>
    </Sheet>
  );
}

// ── Admin ────────────────────────────────────────────────

function AdminSheet({ onClose }: { onClose: () => void }) {
  const { toast } = useApp();
  const [settings, setSettings] = useState<AdminSettings | null>(null);
  const [apiKey, setApiKey] = useState("");
  const [test, setTest] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api<AdminSettings>("GET", "/admin/settings").then(setSettings).catch(() => {});
  }, []);
  if (!settings) return null;

  return (
    <Sheet title="Servidor Evolution" onClose={onClose}>
      <label className="label">URL de Evolution</label>
      <input className="field" value={settings.evolutionBaseUrl} onChange={(e) => setSettings({ ...settings, evolutionBaseUrl: e.target.value })} />
      <label className="label">API key global {settings.evolutionGlobalApiKeySet && "(configurada — escribe para cambiar)"}</label>
      <input className="field" type="password" value={apiKey} onChange={(e) => setApiKey(e.target.value)} />
      <label className="label">Servidor ntfy</label>
      <input className="field" value={settings.ntfyBaseUrl} onChange={(e) => setSettings({ ...settings, ntfyBaseUrl: e.target.value })} />
      <div style={{ display: "flex", gap: 8, marginTop: 16 }}>
        <button
          className="btn"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              await api("PUT", "/admin/settings", {
                evolutionBaseUrl: settings.evolutionBaseUrl,
                evolutionGlobalApiKey: apiKey || undefined,
                ntfyBaseUrl: settings.ntfyBaseUrl,
              });
              toast("Guardado ✓");
            } catch (e) {
              toast(e instanceof ApiError ? e.message : "Error");
            } finally {
              setBusy(false);
            }
          }}
        >
          Guardar
        </button>
        <button
          className="btn secondary"
          disabled={busy}
          onClick={async () => {
            try {
              const r = await api<{ ok: boolean; version: string }>("POST", "/admin/settings/test");
              setTest(r.ok ? `Conectado — Evolution v${r.version}` : `Versión no soportada: ${r.version}`);
            } catch (e) {
              setTest(`Error: ${e instanceof ApiError ? e.message : "sin conexión"}`);
            }
          }}
        >
          Probar conexión
        </button>
      </div>
      {test && <p style={{ marginTop: 10 }}>{test}</p>}
    </Sheet>
  );
}

function UsersSheet({ onClose }: { onClose: () => void }) {
  const { user: me, toast } = useApp();
  const [users, , reload] = useAsync(() => api<Paginated<User>>("GET", "/admin/users"), []);
  const [invite, setInvite] = useState<{ code: string; expiresAt: string } | null>(null);

  return (
    <Sheet title="Usuarios e invitaciones" onClose={onClose}>
      <div className="card">
        {(users?.items ?? []).map((u) => (
          <div key={u.id} className="row" style={{ cursor: "default" }}>
            <div className="main">
              <div className="name" style={{ fontSize: 14 }}>{u.name}</div>
              <div className="sub">{u.email}</div>
            </div>
            <span className={`badge ${u.role === "ADMIN" ? "green" : ""}`}>{u.role === "ADMIN" ? "Admin" : "Usuario"}</span>
            {u.id !== me.id && (
              <>
                <button
                  className="btn small secondary"
                  onClick={async () => {
                    await api("PATCH", `/admin/users/${u.id}`, { role: u.role === "ADMIN" ? "USER" : "ADMIN" }).catch(() => toast("Error"));
                    reload();
                  }}
                >
                  {u.role === "ADMIN" ? "Quitar admin" : "Hacer admin"}
                </button>
                <button
                  className="btn small danger"
                  onClick={async () => {
                    if (!confirm(`¿Eliminar a ${u.name}? Se borran sus instancias y mensajes.`)) return;
                    await api("DELETE", `/admin/users/${u.id}`).catch(() => toast("Error"));
                    reload();
                  }}
                >
                  <IconTrash size={15} />
                </button>
              </>
            )}
          </div>
        ))}
      </div>
      <button
        className="btn secondary"
        style={{ marginTop: 14 }}
        onClick={async () => setInvite(await api("POST", "/admin/invites"))}
      >
        Crear código de invitación
      </button>
      {invite && (
        <div className="code" style={{ marginTop: 10, fontSize: 22 }}>
          {invite.code}
          <div className="hint">Expira {new Date(invite.expiresAt).toLocaleDateString("es")}</div>
        </div>
      )}
    </Sheet>
  );
}
