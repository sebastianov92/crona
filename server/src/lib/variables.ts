import { DateTime } from "luxon";

// Variables de texto, evaluadas al momento del envío en la zona del mensaje:
//   {nombre}        → nombre completo del destinatario (o de quien escribe, en auto-respuestas)
//   {primer_nombre} → solo la primera palabra ("Dani Vega" → "Dani")
//   {fecha}         → "lunes 20 de julio"
//   {dia}           → "lunes"
export function renderVariables(text: string, msg: { recipientName: string; timezone: string }): string {
  const now = DateTime.now().setZone(msg.timezone).setLocale("es");
  return text
    .replaceAll("{nombre}", msg.recipientName)
    .replaceAll("{primer_nombre}", msg.recipientName.trim().split(/\s+/)[0] ?? "")
    .replaceAll("{fecha}", now.toFormat("cccc d 'de' LLLL"))
    .replaceAll("{dia}", now.toFormat("cccc"));
}
