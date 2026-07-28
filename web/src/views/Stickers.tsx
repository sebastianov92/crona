import { useEffect, useState } from "react";
import { ApiError, deleteSticker, fetchMediaBlob, listStickers, markStickerUsed, uploadSticker } from "../api";
import { useApp } from "../App";
import { Sheet } from "../lib";
import { IconPlus, IconTrash } from "../icons";
import type { StickerAsset } from "../types";

/** Una miniatura de la biblioteca: descarga su webp, hace un blob URL propio y lo revoca al desmontar. */
function StickerThumb({
  sticker,
  onPick,
  onDelete,
}: {
  sticker: StickerAsset;
  onPick: (s: StickerAsset, blob: Blob) => void;
  onDelete: () => void;
}) {
  const [url, setUrl] = useState<string | null>(null);
  const [blob, setBlob] = useState<Blob | null>(null);

  useEffect(() => {
    let alive = true;
    let created: string | null = null;
    fetchMediaBlob(sticker.mediaId).then((b) => {
      if (!alive || !b) return;
      setBlob(b);
      created = URL.createObjectURL(b);
      setUrl(created);
    });
    return () => {
      alive = false;
      if (created) URL.revokeObjectURL(created);
    };
  }, [sticker.mediaId]);

  return (
    <div className="stickercell">
      <button
        className="stickerpick"
        disabled={!blob}
        title="Usar sticker"
        onClick={() => blob && onPick(sticker, blob)}
      >
        {url ? <img src={url} alt="sticker" /> : <span className="stickerph" />}
      </button>
      <button className="stickerdel" title="Eliminar" aria-label="Eliminar sticker" onClick={onDelete}>
        <IconTrash size={14} />
      </button>
    </div>
  );
}

/**
 * Menú de stickers estilo WhatsApp. Al elegir uno: descarga su webp, lo convierte en un File
 * marcado como sticker (onPick) y lo marca como recién usado. Recientes primero (orden del server).
 */
export function StickersSheet({ onClose, onPick }: { onClose: () => void; onPick: (file: File) => void }) {
  const { toast } = useApp();
  const [items, setItems] = useState<StickerAsset[] | null>(null);
  const [busy, setBusy] = useState(false);

  const load = async () => {
    try {
      setItems((await listStickers()).items);
    } catch {
      toast("No se pudieron cargar los stickers");
      setItems([]);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const add = async (file: File) => {
    setBusy(true);
    try {
      await uploadSticker(file);
      await load();
      toast("Sticker añadido ✓");
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al añadir el sticker");
    } finally {
      setBusy(false);
    }
  };

  const remove = async (s: StickerAsset) => {
    try {
      await deleteSticker(s.id);
      setItems((prev) => prev?.filter((x) => x.id !== s.id) ?? null);
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Error al eliminar");
    }
  };

  const pick = (s: StickerAsset, blob: Blob) => {
    onPick(new File([blob], "sticker.webp", { type: "image/webp" }));
    markStickerUsed(s.id).catch(() => {});
    onClose();
  };

  const addBtn = (
    <label className="btn small secondary" style={{ cursor: busy ? "default" : "pointer" }}>
      <IconPlus size={14} /> Añadir
      <input
        type="file"
        hidden
        accept="image/webp,image/png,image/jpeg"
        disabled={busy}
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) add(f);
          e.target.value = "";
        }}
      />
    </label>
  );

  return (
    <Sheet title="Mis stickers" onClose={onClose} actions={addBtn}>
      {items === null ? (
        <div className="empty">
          <span className="spin dark" />
        </div>
      ) : items.length === 0 ? (
        <div className="empty">
          No tienes stickers guardados todavía.
          <br />
          Activa <b>Guardar mis stickers</b> en Ajustes para capturarlos automáticamente cuando te los envíes a ti
          mismo por WhatsApp, o añade uno con el botón Añadir.
        </div>
      ) : (
        <div className="stickergrid">
          {items.map((s) => (
            <StickerThumb key={s.id} sticker={s} onPick={pick} onDelete={() => remove(s)} />
          ))}
        </div>
      )}
    </Sheet>
  );
}
