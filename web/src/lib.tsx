import { ReactNode, useEffect, useState } from "react";
import { mediaBlobURL } from "./api";
import { IconPaperclip } from "./icons";
import type { LogStatus, MessageType, Recurrence, ScheduleStatus } from "./types";

/** Logo completo "Crona": texto negro en tema claro, blanco en oscuro (los SVG traen la burbuja verde). */
export function LogoFull({ width = 220 }: { width?: number }) {
  // el arte útil del SVG ocupa la franja central del lienzo 1920×1080 — recorte visual vía aspect-ratio
  const style = { width, height: width * 0.36, objectFit: "cover" as const, objectPosition: "center" };
  return (
    <>
      <img className="logofull light-only" src="/app/logo-light.svg" alt="Crona" style={style} />
      <img className="logofull dark-only" src="/app/logo-dark.svg" alt="Crona" style={style} />
    </>
  );
}

export function Avatar({ name, url, size = 44 }: { name: string; url?: string | null; size?: number }) {
  const initials = name
    .split(" ")
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase() ?? "")
    .join("");
  return (
    <div className="avatar" style={{ width: size, height: size, fontSize: size * 0.36 }}>
      {url ? <img src={url} alt="" onError={(e) => ((e.target as HTMLImageElement).style.display = "none")} /> : initials || "?"}
    </div>
  );
}

export function Sheet({ title, onClose, children, actions }: { title: string; onClose: () => void; children: ReactNode; actions?: ReactNode }) {
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet">
        <div className="sheethead">
          <h2>{title}</h2>
          <div className="actions">
            {actions}
            <button className="btn small secondary" onClick={onClose}>✕</button>
          </div>
        </div>
        {children}
      </div>
    </div>
  );
}

export function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return <button className={`toggle ${on ? "on" : ""}`} onClick={() => onChange(!on)} aria-checked={on} role="switch" />;
}

export function MediaImg({ mediaId, type }: { mediaId: string; type: MessageType }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (type === "IMAGE") mediaBlobURL(mediaId).then(setUrl);
  }, [mediaId, type]);
  if (type !== "IMAGE")
    return (
      <div className="hint" style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <IconPaperclip size={14} />{" "}
        {type === "VIDEO" ? "Video adjunto" : type === "AUDIO" ? "Nota de voz adjunta" : "Documento adjunto"}
      </div>
    );
  return url ? <img className="mediathumb" src={url} alt="adjunto" /> : <div className="hint">Cargando adjunto…</div>;
}

export function scheduleLabel(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const hora = d.toLocaleTimeString("es", { hour: "numeric", minute: "2-digit" });
  const sameDay = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  if (sameDay(d, now)) return `Hoy ${hora}`;
  if (sameDay(d, tomorrow)) return `Mañana ${hora}`;
  const days = (d.getTime() - now.getTime()) / 86400000;
  if (days > 0 && days < 7) return d.toLocaleDateString("es", { weekday: "short" }) + ` ${hora}`;
  return d.toLocaleDateString("es", { day: "numeric", month: "short" }) + ` ${hora}`;
}

export function messagePreview(type: MessageType, body: string | null): string {
  const labels: Record<MessageType, string> = { TEXT: "", IMAGE: "Foto", VIDEO: "Video", DOCUMENT: "Documento", AUDIO: "Nota de voz" };
  if (type === "TEXT") return body ?? "";
  return body ? `${labels[type]} · ${body}` : labels[type];
}

export const statusLabel: Record<ScheduleStatus, string> = {
  ACTIVE: "Programado",
  PAUSED: "Pausado",
  COMPLETED: "Completado",
  CANCELLED: "Cancelado",
  FAILED: "Fallido",
};

export const logLabel: Record<LogStatus, string> = {
  SENDING: "Enviando…",
  SENT: "Enviado ✓",
  DELIVERED: "Entregado ✓✓",
  READ: "Leído ✓✓",
  FAILED: "Fallido ✗",
};

export const recurrenceLabel: Record<Recurrence, string> = {
  NONE: "No se repite",
  DAILY: "Todos los días",
  WEEKLY: "Semanal",
  MONTHLY: "Mensual",
  YEARLY: "Cada año",
};

export const dayNames = ["", "L", "M", "X", "J", "V", "S", "D"];

export function DayDots({ value, onChange }: { value: Set<number>; onChange: (v: Set<number>) => void }) {
  return (
    <div className="daydots">
      {[1, 2, 3, 4, 5, 6, 7].map((n) => (
        <button
          key={n}
          className={value.has(n) ? "on" : ""}
          onClick={() => {
            const next = new Set(value);
            next.has(n) ? next.delete(n) : next.add(n);
            onChange(next);
          }}
        >
          {dayNames[n]}
        </button>
      ))}
    </div>
  );
}

export function useAsync<T>(fn: () => Promise<T>, deps: unknown[]): [T | null, boolean, () => void] {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setLoading(true);
    fn()
      .then((d) => alive && setData(d))
      .catch(() => {})
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return [data, loading, () => setTick((t) => t + 1)];
}
