-- Guardar todos los ids de Evolution por envío (split): "eliminar para todos" borra las N partes.
ALTER TABLE "MessageLog" ADD COLUMN "evolutionMessageIds" TEXT[] NOT NULL DEFAULT '{}';
