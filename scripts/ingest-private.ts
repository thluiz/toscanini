#!/usr/bin/env bun
/**
 * Envia MP3 de cursos/aulas para o Toscanini como conteúdo PRIVADO.
 *
 *   bun scripts/ingest-private.ts --course "Nome do Curso" [--author "Nome"] [--title "Título"] [--dry-run] <arquivo-ou-pasta>...
 *
 * --title (só com um arquivo) substitui o título tirado do nome do arquivo.
 *
 * Para cada MP3: copia para /home/hermes/collected (HermesTools) com o slug "<curso>-<arquivo>",
 * mede a duração com o ffprobe de lá e chama POST /ingest/local com private: true. O pipeline
 * transcreve, resume e escreve no vox-private-content; o MP3 fica retido.
 *
 * Pode ser rodado de novo com os mesmos arquivos (e com arquivos novos na mesma pasta): o slug é
 * estável, a cópia é pulada quando o tamanho já bate e o servidor ignora o que já foi enviado.
 */
import { readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { buildPayload, episodeSlug } from "./ingest-private-lib";

const DISTRO = ["-d", "HermesTools", "-u", "hermes"];
const COLLECTED = "/home/hermes/collected";
const BASE_URL = process.env.TOSCANINI_URL ?? "http://localhost:8080/api/orchestrator";

const args = process.argv.slice(2);
const flag = (name: string) => args.includes(name);
const opt = (name: string) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const valueFlags = new Set(["--course", "--author", "--title"]);
const paths = args.filter((a, i) => !a.startsWith("--") && !valueFlags.has(args[i - 1] ?? ""));

const course = opt("--course");
const author = opt("--author");
const title = opt("--title");
const dryRun = flag("--dry-run");

if (title && paths.length !== 1) {
  console.error("--title só vale para um único arquivo");
  process.exit(2);
}

if (!course || paths.length === 0) {
  console.error('uso: bun scripts/ingest-private.ts --course "Nome do Curso" [--author "Nome"] [--title "Título"] [--dry-run] <arquivo-ou-pasta>...');
  process.exit(2);
}

/** Roda um comando no HermesTools sem shell do Windows no meio. */
async function wsl(cmd: string[], stdin?: Blob): Promise<string> {
  const p = Bun.spawn(["wsl", ...DISTRO, "-e", ...cmd], { stdin: stdin ?? "ignore", stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`wsl ${cmd.join(" ")} falhou (${code}): ${err.trim()}`);
  return out;
}

function listMp3(target: string): string[] {
  const st = statSync(target);
  if (st.isFile()) return /\.mp3$/i.test(target) ? [target] : [];
  return readdirSync(target, { withFileTypes: true })
    .flatMap((e) => (e.isDirectory() ? listMp3(join(target, e.name)) : /\.mp3$/i.test(e.name) ? [join(target, e.name)] : []))
    .sort((a, b) => a.localeCompare(b, "pt-BR", { numeric: true }));
}

const files = paths.flatMap(listMp3);
if (files.length === 0) {
  console.error("nenhum .mp3 encontrado");
  process.exit(1);
}

console.error(`${files.length} arquivo(s) do curso "${course}"${dryRun ? " (dry-run: nada será copiado nem enviado)" : ""}`);

const results = { queued: 0, duplicate: 0, failed: 0 };

for (const file of files) {
  const name = basename(file);
  const slug = episodeSlug(course, name);
  const remote = `${COLLECTED}/${slug}.mp3`;

  if (dryRun) {
    console.log(`DRY  ${name}  ->  ${slug}`);
    continue;
  }

  try {
    const size = statSync(file).size;
    const existing = await wsl(["sh", "-c", `stat -c %s "${remote}" 2>/dev/null || echo 0`]);
    if (Number(existing.trim()) !== size) {
      await wsl(["sh", "-c", `cat > "${remote}"`], Bun.file(file));
      const copied = Number((await wsl(["stat", "-c", "%s", remote])).trim());
      if (copied !== size) throw new Error(`cópia incompleta: ${copied} != ${size} bytes`);
    }

    const durationSecs = Number((await wsl(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", remote])).trim());
    if (!Number.isFinite(durationSecs) || durationSecs <= 0) throw new Error("não consegui ler a duração");

    const payload = buildPayload({
      course,
      filename: name,
      title,
      durationSecs,
      publishedIso: statSync(file).mtime.toISOString().slice(0, 10),
      author,
      uuid: crypto.randomUUID(),
    });

    const res = await fetch(`${BASE_URL}/ingest/local`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    const body = (await res.json().catch(() => ({}))) as { job_id?: string; duplicate?: boolean; error?: string };
    if (!res.ok) throw new Error(body.error ?? `HTTP ${res.status}`);

    if (body.duplicate) {
      results.duplicate++;
      console.log(`JÁ   ${name}  (${slug})`);
    } else {
      results.queued++;
      console.log(`FILA ${name}  ->  ${slug}  [${body.job_id}]`);
    }
  } catch (e) {
    results.failed++;
    console.log(`ERRO ${name}: ${e instanceof Error ? e.message : e}`);
  }
}

console.error(`\nenfileirados: ${results.queued} | já enviados: ${results.duplicate} | erros: ${results.failed}`);
process.exit(results.failed > 0 ? 1 : 0);
