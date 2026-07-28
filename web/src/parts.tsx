// Partes de un mensaje: una lista homogénea donde CADA parte tiene su propio tipo
// (texto, foto/video, nota de voz o sticker) y su propio adjunto opcional. El servidor
// las envía una tras otra, cada una con su "escribiendo…" y una pausa corta entre ellas.
import { useEffect, useRef, useState } from "react";
import { useApp } from "./App";
import { IconCamera, IconMic, IconPlus, IconSticker, IconStop, IconText, IconTrash, IconVideo } from "./icons";
import type { MessageType, TemplatePart } from "./types";

export const MAX_PARTS = 10;
/** typingMs por defecto para media sin caption (foto/video): un valor corto. */
const DEFAULT_MEDIA_TYPING = 2500;

export const clampTyping = (ms: number | null): number | null =>
  ms === null ? null : Math.max(1500, Math.min(25_000, Math.round(ms)));

export type PartKind = "text" | "photo" | "audio" | "sticker";

export interface PartDraft {
  key: string;
  kind: PartKind;
  /** texto de la parte; también sirve de caption en foto/video */
  body: string;
  /** instante del primer carácter escrito en ESTA parte */
  typingStart: number | null;
  /** typingMs heredado (plantilla o edición) — se usa si el usuario no reescribe */
  typingMs: number | null;
  /** adjunto de la parte (foto/video, nota de voz o sticker) */
  file: File | null;
  /** duración de la nota de voz grabada */
  durationMs: number | null;
}

let seq = 0;
const mk = (kind: PartKind, over: Partial<PartDraft> = {}): PartDraft => ({
  key: `p${++seq}`,
  kind,
  body: "",
  typingStart: null,
  typingMs: null,
  file: null,
  durationMs: null,
  ...over,
});

export const newPart = (body = "", typingMs: number | null = null): PartDraft => mk("text", { body, typingMs });
export const newMediaPart = (kind: PartKind, file: File | null, durationMs: number | null = null): PartDraft =>
  mk(kind, { file, durationMs });

export const partsFromTemplate = (parts: TemplatePart[]): PartDraft[] =>
  parts.length ? parts.map((p) => newPart(p.body, p.typingMs ?? null)) : [newPart()];

/** Tipo de mensaje del servidor para esta parte. */
export const partMessageType = (p: PartDraft): MessageType =>
  p.kind === "audio"
    ? "AUDIO"
    : p.kind === "sticker"
      ? "STICKER"
      : p.kind === "photo"
        ? p.file?.type.startsWith("video/")
          ? "VIDEO"
          : "IMAGE"
        : "TEXT";

/** typingMs de la parte: texto = escritura real; audio = duración; foto/video = caption o corto; sticker = nada. */
export const partTypingMs = (p: PartDraft): number | null => {
  if (p.kind === "audio") return clampTyping(p.durationMs);
  if (p.kind === "sticker") return null;
  if (p.typingStart) return clampTyping(Date.now() - p.typingStart);
  if (p.kind === "photo" && !p.body.trim()) return clampTyping(DEFAULT_MEDIA_TYPING);
  return clampTyping(p.typingMs);
};

/** ¿La parte está lista para enviarse? Texto necesita cuerpo; media necesita archivo. */
export const partReady = (p: PartDraft): boolean => (p.kind === "text" ? !!p.body.trim() : !!p.file);

/** Partes de texto listas para el cuerpo de una plantilla (solo texto). */
export const packParts = (parts: PartDraft[]): { body: string; typingMs: number | null }[] =>
  parts.filter((p) => p.kind === "text" && p.body.trim()).map((p) => ({ body: p.body.trim(), typingMs: partTypingMs(p) }));

const fmtDur = (ms: number | null): string => {
  const s = Math.round((ms ?? 0) / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

const kindLabel = (p: PartDraft): string =>
  p.kind === "audio"
    ? "Nota de voz"
    : p.kind === "sticker"
      ? "Sticker"
      : p.kind === "photo"
        ? p.file?.type.startsWith("video/")
          ? "Video"
          : "Foto"
        : "Texto";

// ── Caja de texto con altura acotada + auto-scroll ───────
// Crece hasta un máximo (~5 líneas) y luego scrollea internamente, así el cursor
// (última línea) nunca queda tapado por el teclado. Al enfocar/escribir, hace
// scrollIntoView para que la parte activa quede visible sobre el teclado.
export function AutoTextArea({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  const ref = useRef<HTMLTextAreaElement>(null);
  const fit = () => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`; // CSS acota con max-height y activa el scroll interno
  };
  useEffect(fit, [value]);
  return (
    <textarea
      ref={ref}
      className="field partinput"
      placeholder={placeholder}
      value={value}
      rows={1}
      onChange={(e) => onChange(e.target.value)}
      onInput={(e) => {
        fit();
        e.currentTarget.scrollIntoView({ block: "nearest" });
      }}
      onFocus={(e) => e.currentTarget.scrollIntoView({ block: "nearest" })}
    />
  );
}

/** Miniatura local de un File (imagen/sticker); video u otros muestran un icono. */
function LocalThumb({ file }: { file: File }) {
  const [url, setUrl] = useState<string | null>(null);
  const isImage = file.type.startsWith("image/");
  useEffect(() => {
    if (!isImage) return;
    const u = URL.createObjectURL(file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [file, isImage]);
  if (isImage && url) return <img className="partthumb" src={url} alt="" />;
  return (
    <div className="particon">
      <IconVideo size={22} />
    </div>
  );
}

// ── Editor de plantillas (solo texto) ────────────────────
// Se mantiene para plantillas y mensaje inicial de grupo, que solo admiten texto.
export function PartsEditor({
  parts,
  onChange,
  placeholder = "Escribe un mensaje",
  note,
  max = MAX_PARTS,
}: {
  parts: PartDraft[];
  onChange: (p: PartDraft[]) => void;
  placeholder?: string;
  note?: string;
  max?: number;
}) {
  const setBody = (i: number, value: string) =>
    onChange(
      parts.map((p, idx) =>
        idx === i ? { ...p, body: value, typingStart: p.typingStart ?? (value ? Date.now() : null) } : p,
      ),
    );

  return (
    <>
      {note && <div className="hint">{note}</div>}
      {parts.map((p, i) => (
        <div key={p.key} className="partbox">
          {parts.length > 1 && (
            <div className="parthead">
              <span>Mensaje {i + 1}</span>
              {i > 0 && (
                <button
                  type="button"
                  className="btn small secondary"
                  title="Quitar este mensaje"
                  onClick={() => onChange(parts.filter((_, idx) => idx !== i))}
                >
                  <IconTrash size={14} />
                </button>
              )}
            </div>
          )}
          <AutoTextArea value={p.body} onChange={(v) => setBody(i, v)} placeholder={placeholder} />
        </div>
      ))}
      {parts.length < max && (
        <button type="button" className="btn ghost" style={{ padding: "6px 0" }} onClick={() => onChange([...parts, newPart()])}>
          <IconPlus size={15} /> Agregar otro mensaje
        </button>
      )}
      {parts.length > 1 && <div className="hint">Se envían uno tras otro, con una pausa corta entre cada uno.</div>}
    </>
  );
}

// ── Compositor multi-tipo (mensajes programados) ─────────
export function PartsComposer({
  parts,
  onChange,
  onAddFromLibrary,
  max = MAX_PARTS,
}: {
  parts: PartDraft[];
  onChange: (p: PartDraft[]) => void;
  /** abre la biblioteca "Mis stickers"; el padre agrega la parte de sticker al elegir */
  onAddFromLibrary: () => void;
  max?: number;
}) {
  const [menu, setMenu] = useState(false);
  const update = (i: number, patch: Partial<PartDraft>) => onChange(parts.map((p, idx) => (idx === i ? { ...p, ...patch } : p)));
  const add = (p: PartDraft) => {
    onChange([...parts, p]);
    setMenu(false);
  };
  const setText = (i: number, value: string) =>
    update(i, { body: value, typingStart: parts[i].typingStart ?? (value ? Date.now() : null) });

  return (
    <>
      {parts.map((p, i) => (
        <div key={p.key} className="partbox">
          <div className="parthead">
            <span>
              Mensaje {i + 1} · {kindLabel(p)}
            </span>
            {parts.length > 1 && (
              <button
                type="button"
                className="btn small secondary"
                title="Quitar esta parte"
                onClick={() => onChange(parts.filter((_, idx) => idx !== i))}
              >
                <IconTrash size={14} />
              </button>
            )}
          </div>

          {p.kind === "text" && (
            <AutoTextArea value={p.body} onChange={(v) => setText(i, v)} placeholder="Escribe un mensaje" />
          )}

          {p.kind === "photo" && p.file && (
            <div className="partmedia">
              <LocalThumb file={p.file} />
              <div style={{ flex: 1 }}>
                <AutoTextArea value={p.body} onChange={(v) => setText(i, v)} placeholder="Texto opcional…" />
              </div>
            </div>
          )}

          {p.kind === "sticker" && p.file && (
            <div className="partmedia">
              <LocalThumb file={p.file} />
            </div>
          )}

          {p.kind === "audio" &&
            (p.file ? (
              <div className="kv" style={{ alignItems: "center", borderBottom: "none" }}>
                <span style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <IconMic size={14} /> Nota de voz · {fmtDur(p.durationMs)}
                </span>
                <button className="btn small secondary" onClick={() => update(i, { file: null, durationMs: null })}>
                  Regrabar
                </button>
              </div>
            ) : (
              <VoiceRecorderButton onDone={(f, dur) => update(i, { file: f, durationMs: dur ?? null })} />
            ))}
        </div>
      ))}

      {parts.length < max && (
        <>
          <button type="button" className="btn ghost" style={{ padding: "6px 0" }} onClick={() => setMenu((v) => !v)}>
            <IconPlus size={15} /> Agregar parte
          </button>
          {menu && (
            <div className="addmenu">
              <button type="button" className="addopt" onClick={() => add(newPart())}>
                <IconText size={17} /> Texto
              </button>
              <label className="addopt">
                <IconCamera size={17} /> Foto o video
                <input
                  type="file"
                  hidden
                  accept="image/jpeg,image/png,image/webp,video/mp4,video/quicktime"
                  onChange={(e) => {
                    const f = e.target.files?.[0];
                    if (f) add(newMediaPart("photo", f));
                    e.target.value = "";
                  }}
                />
              </label>
              <button type="button" className="addopt" onClick={() => add(newMediaPart("audio", null))}>
                <IconMic size={17} /> Nota de voz
              </button>
              <label className="addopt">
                <IconSticker size={17} /> Sticker (archivo)
                <input
                  type="file"
                  hidden
                  accept="image/webp,image/png,image/jpeg"
                  onChange={(e) => {
                    const f = e.target.files?.[0];
                    if (f) add(newMediaPart("sticker", f));
                    e.target.value = "";
                  }}
                />
              </label>
              <button
                type="button"
                className="addopt"
                onClick={() => {
                  onAddFromLibrary();
                  setMenu(false);
                }}
              >
                <IconSticker size={17} /> Mis stickers
              </button>
            </div>
          )}
        </>
      )}

      {parts.length > 1 && <div className="hint">Se envían uno tras otro, con una pausa corta entre cada uno.</div>}
    </>
  );
}

// ── Grabador de notas de voz ─────────────────────────────
// (vive aquí para que lo reutilicen tanto el compositor de partes como el chat)
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
