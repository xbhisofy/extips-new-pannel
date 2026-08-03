const SUPABASE_URL =
  (import.meta as any).env?.VITE_SUPABASE_URL?.replace(/\/$/, "") || "";

/** Build a proxied Instagram image/thumbnail URL that works on any backend host. */
export function igImageUrl(url?: string | null): string | undefined {
  if (!url) return undefined;
  if (!SUPABASE_URL) return url;
  return `${SUPABASE_URL}/functions/v1/ig-image-proxy?url=${encodeURIComponent(url)}`;
}
