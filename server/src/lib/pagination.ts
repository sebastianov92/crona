// Cursor opaco: base64url del id del último item de la página.
export const encodeCursor = (id: string) => Buffer.from(id).toString("base64url");
export const decodeCursor = (cursor: string | undefined): string | undefined =>
  cursor ? Buffer.from(cursor, "base64url").toString() : undefined;
