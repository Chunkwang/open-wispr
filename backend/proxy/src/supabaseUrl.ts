/** SUPABASE_URL without trailing slashes, so every consumer builds identical URLs and issuer strings. */
export function supabaseBaseUrl(url: string | undefined): string {
  return (url ?? "").replace(/\/+$/, "");
}
