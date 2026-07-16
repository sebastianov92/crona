export type ErrorCode =
  | "INVALID_CREDENTIALS"
  | "INVITE_REQUIRED"
  | "INVITE_INVALID"
  | "TOKEN_EXPIRED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "VALIDATION_ERROR"
  | "INSTANCE_DISCONNECTED"
  | "EVOLUTION_UNREACHABLE"
  | "MEDIA_TOO_LARGE"
  | "MEDIA_TYPE_UNSUPPORTED"
  | "MESSAGE_NOT_EDITABLE"
  | "RATE_LIMITED"
  | "INTERNAL_ERROR";

export class AppError extends Error {
  constructor(
    public statusCode: number,
    public code: ErrorCode,
    message: string,
  ) {
    super(message);
  }
}

export const errors = {
  invalidCredentials: () => new AppError(401, "INVALID_CREDENTIALS", "Email o contraseña incorrectos."),
  inviteRequired: () => new AppError(403, "INVITE_REQUIRED", "Necesitas un código de invitación para registrarte."),
  inviteInvalid: () => new AppError(403, "INVITE_INVALID", "El código de invitación no es válido o ya expiró."),
  tokenExpired: () => new AppError(401, "TOKEN_EXPIRED", "Tu sesión expiró. Inicia sesión de nuevo."),
  forbidden: () => new AppError(403, "FORBIDDEN", "No tienes permiso para hacer esto."),
  notFound: (what = "El recurso") => new AppError(404, "NOT_FOUND", `${what} no existe.`),
  validation: (message: string) => new AppError(400, "VALIDATION_ERROR", message),
  instanceDisconnected: () => new AppError(409, "INSTANCE_DISCONNECTED", "La instancia de WhatsApp está desconectada."),
  evolutionUnreachable: (detail?: string) =>
    new AppError(502, "EVOLUTION_UNREACHABLE", `No se pudo conectar con Evolution API${detail ? `: ${detail}` : "."}`),
  mediaTooLarge: (limitMb: number) =>
    new AppError(413, "MEDIA_TOO_LARGE", `El archivo supera el límite de ${limitMb} MB.`),
  mediaTypeUnsupported: () =>
    new AppError(415, "MEDIA_TYPE_UNSUPPORTED", "Tipo de archivo no soportado. Usa JPG, PNG, WebP, MP4, MOV o PDF."),
  messageNotEditable: () =>
    new AppError(409, "MESSAGE_NOT_EDITABLE", "Este mensaje ya no se puede editar."),
};
