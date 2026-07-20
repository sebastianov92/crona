import { useState } from "react";
import { api } from "../api";
import { useApp } from "../App";
import { Avatar, logLabel, messagePreview, scheduleLabel, useAsync } from "../lib";
import type { HistoryItem, Paginated } from "../types";

export default function History() {
  const { toast } = useApp();
  const [search, setSearch] = useState("");
  const [data, , reload] = useAsync(() => api<Paginated<HistoryItem>>("GET", "/messages?filter=history"), []);
  const [hidden, setHidden] = useState<Set<string>>(new Set());

  const items = (data?.items ?? []).filter(
    (i) =>
      !hidden.has(i.id) &&
      (!search || i.recipientName.toLowerCase().includes(search.toLowerCase()) || (i.body ?? "").toLowerCase().includes(search.toLowerCase())),
  );

  const remove = async (item: HistoryItem) => {
    setHidden((h) => new Set(h).add(item.id));
    try {
      await api("DELETE", `/messages/logs/${item.id}`);
    } catch {
      toast("No se pudo borrar");
      reload();
    }
  };

  return (
    <div className="page">
      <h1 className="pagetitle">Historial</h1>
      <input className="field" placeholder="🔍 Buscar" value={search} onChange={(e) => setSearch(e.target.value)} style={{ marginBottom: 12 }} />
      <div className="card">
        {items.length === 0 && <div className="empty">Aún no hay envíos en el historial.</div>}
        {items.map((i) => (
          <div key={i.id} className="row" style={{ cursor: "default" }}>
            <Avatar name={i.recipientName} url={i.recipientPictureUrl} />
            <div className="main">
              <div className="name">{i.recipientName}</div>
              <div className="sub" style={{ color: i.error ? "var(--danger)" : undefined }}>
                {i.error ?? messagePreview(i.type, i.body)}
              </div>
            </div>
            <div className="right">
              <div className="state">{scheduleLabel(i.runAt)}</div>
              <div className="time" style={{ color: i.status === "FAILED" ? "var(--danger)" : "var(--accent)" }}>
                {logLabel[i.status]}
              </div>
            </div>
            <button className="btn small danger" title="Borrar" onClick={() => remove(i)}>🗑</button>
          </div>
        ))}
      </div>
    </div>
  );
}
