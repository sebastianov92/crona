// Partes de un mensaje dividido (split): varias cajas de texto que el servidor envía
// una tras otra, cada una con su propio tiempo de "escribiendo…".
import { IconPlus, IconTrash } from "./icons";
import type { TemplatePart } from "./types";

export const MAX_PARTS = 10;

export const clampTyping = (ms: number | null): number | null =>
  ms === null ? null : Math.max(1500, Math.min(25_000, Math.round(ms)));

export interface PartDraft {
  key: string;
  body: string;
  /** instante del primer carácter escrito en ESTA parte */
  typingStart: number | null;
  /** typingMs heredado (plantilla o edición) — se usa si el usuario no reescribe */
  typingMs: number | null;
}

let seq = 0;
export const newPart = (body = "", typingMs: number | null = null): PartDraft => ({
  key: `p${++seq}`,
  body,
  typingStart: null,
  typingMs,
});

export const partsFromTemplate = (parts: TemplatePart[]): PartDraft[] =>
  parts.length ? parts.map((p) => newPart(p.body, p.typingMs ?? null)) : [newPart()];

/** Tiempo de escritura real de la parte; si no se escribió, el heredado. */
export const partTypingMs = (p: PartDraft): number | null =>
  clampTyping(p.typingStart ? Date.now() - p.typingStart : p.typingMs);

/** Partes con texto, listas para el cuerpo de la petición. */
export const packParts = (parts: PartDraft[]): { body: string; typingMs: number | null }[] =>
  parts.filter((p) => p.body.trim()).map((p) => ({ body: p.body.trim(), typingMs: partTypingMs(p) }));

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
  /** aviso mostrado encima de las cajas */
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
      {parts.map((p, i) => {
        return (
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
            <textarea
              className="field"
              placeholder={placeholder}
              value={p.body}
              onChange={(e) => setBody(i, e.target.value)}
            />
          </div>
        );
      })}
      {parts.length < max && (
        <button type="button" className="btn ghost" style={{ padding: "6px 0" }} onClick={() => onChange([...parts, newPart()])}>
          <IconPlus size={15} /> Agregar otro mensaje
        </button>
      )}
      {parts.length > 1 && (
        <div className="hint">Se envían uno tras otro, con una pausa corta entre cada uno.</div>
      )}
    </>
  );
}
