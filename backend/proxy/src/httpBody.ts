export type BodyResult = { kind: "ok"; text: string } | { kind: "too_large" } | { kind: "bad_encoding" };

/**
 * Reads the request body as UTF-8 text, or reports that it is larger than
 * `maxBytes` or not valid UTF-8. A declared Content-Length over the cap is
 * refused without reading anything; a missing or understated one is caught while
 * streaming, so an oversized body is never fully buffered. Exactly `maxBytes` is accepted.
 *
 * Shared by every route that accepts a body (rewrite, edit, events, referral) so
 * none of them can forget the cap: a body without it is an unbounded-cost path.
 */
export async function readBodyCapped(request: Request, maxBytes: number): Promise<BodyResult> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) return { kind: "too_large" };
  if (!request.body) return { kind: "ok", text: "" };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      return { kind: "too_large" };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { kind: "ok", text: new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes) };
  } catch {
    return { kind: "bad_encoding" };
  }
}
