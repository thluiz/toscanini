/** Funções puras do ingest-private (testadas em ingest-private.test.ts). */

/** "Introdução à Filosofia 01" -> "introducao-a-filosofia-01": minúsculas, sem acento, [a-z0-9-]. */
export function slugify(text: string): string {
  return text
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/**
 * Título legível a partir do nome do arquivo: tira extensão e prefixo de ordem ("03 - ", "03_", "03.").
 * Nome em kebab-case ("aula-extra-uma-visao") vira texto com espaços e a primeira letra maiúscula.
 */
export function titleFromFilename(filename: string): string {
  const base = filename.replace(/\.[^.]+$/, "");
  let cleaned = base.replace(/^\s*\d{1,3}\s*[-_.)]\s*/, "").replace(/[_]+/g, " ").replace(/\s+/g, " ").trim();
  if (cleaned && !cleaned.includes(" ") && cleaned.includes("-")) {
    cleaned = cleaned.replace(/-+/g, " ");
    cleaned = cleaned.charAt(0).toUpperCase() + cleaned.slice(1);
  }
  return cleaned || base.trim();
}

/**
 * Slug estável do episódio: curso + arquivo, sem repetir o que já está no nome do arquivo. As palavras do
 * curso que aparecem no arquivo ("henry-kissinger" em "Petit Cursos: Henry Kissinger" e em
 * "aula-extra-henry-kissinger-...") saem do prefixo. Reenviar o mesmo arquivo gera o mesmo slug (o
 * servidor ignora o repetido).
 */
export function episodeSlug(course: string, filename: string): string {
  const base = filename.replace(/\.[^.]+$/, "");
  const fileSlug = slugify(base);
  const inFile = new Set(fileSlug.split("-"));
  const prefix = slugify(course).split("-").filter((w) => w && !inFile.has(w)).join("-");
  return [prefix, fileSlug].filter(Boolean).join("-");
}

/** 3725 -> "01:02:05" */
export function formatDuration(totalSecs: number): string {
  const s = Math.max(0, Math.round(totalSecs));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return [h, m, sec].map((n) => String(n).padStart(2, "0")).join(":");
}

export interface IngestPayload {
  slug: string;
  duration_secs: number;
  private: true;
  source_url: string;
  json: {
    version: 1;
    metadata: Record<string, unknown>;
    transcript: null;
  };
}

/** Corpo do POST /ingest/local para um arquivo de curso. */
export function buildPayload(opts: {
  course: string;
  filename: string;
  title?: string;
  durationSecs: number;
  publishedIso: string;
  author?: string;
  uuid: string;
}): IngestPayload {
  const title = opts.title?.trim() || titleFromFilename(opts.filename);
  const metadata: Record<string, unknown> = {
    podcast: opts.course,
    title,
    published: opts.publishedIso,
    duration: formatDuration(opts.durationSecs),
    uuid: opts.uuid,
    source: "local",
    source_url: "",
  };
  if (opts.author) metadata.author = opts.author;
  return {
    slug: episodeSlug(opts.course, opts.filename),
    duration_secs: Math.round(opts.durationSecs),
    private: true,
    source_url: "",
    json: { version: 1, metadata, transcript: null },
  };
}
