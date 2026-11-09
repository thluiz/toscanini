import { describe, expect, test } from "bun:test";
import { buildPayload, episodeSlug, formatDuration, slugify, titleFromFilename } from "./ingest-private-lib";

describe("slugify", () => {
  test("tira acento, pontuação e espaços", () => {
    expect(slugify("Introdução à Filosofia — Aula 01!")).toBe("introducao-a-filosofia-aula-01");
    expect(slugify("  --Ética & Moral--  ")).toBe("etica-moral");
  });
  test("vazio continua vazio", () => {
    expect(slugify("???")).toBe("");
  });
});

describe("titleFromFilename", () => {
  test("tira extensão e prefixo de ordem", () => {
    expect(titleFromFilename("03 - O Corpo e a Potência.mp3")).toBe("O Corpo e a Potência");
    expect(titleFromFilename("07_aula_sobre_espinosa.MP3")).toBe("aula sobre espinosa");
    expect(titleFromFilename("12. Zaratustra.mp3")).toBe("Zaratustra");
  });
  test("nome só numérico não vira título vazio", () => {
    expect(titleFromFilename("2026.mp3")).toBe("2026");
  });
});

describe("episodeSlug", () => {
  test("curso + arquivo, estável e só [a-z0-9-]", () => {
    const a = episodeSlug("Curso de Espinosa", "01 - Aula Inaugural.mp3");
    expect(a).toBe("curso-de-espinosa-01-aula-inaugural");
    expect(episodeSlug("Curso de Espinosa", "01 - Aula Inaugural.mp3")).toBe(a);
    expect(a).toMatch(/^[a-z0-9-]+$/);
  });
  test("mesmo arquivo em cursos diferentes gera slugs diferentes", () => {
    expect(episodeSlug("A", "01.mp3")).not.toBe(episodeSlug("B", "01.mp3"));
  });
});

describe("formatDuration", () => {
  test("HH:MM:SS", () => {
    expect(formatDuration(3725)).toBe("01:02:05");
    expect(formatDuration(59.6)).toBe("00:01:00");
    expect(formatDuration(-3)).toBe("00:00:00");
  });
});

describe("buildPayload", () => {
  const base = {
    course: "Curso de Espinosa",
    filename: "02 - Os Afetos.mp3",
    durationSecs: 3601.4,
    publishedIso: "2026-11-09",
    uuid: "11111111-2222-3333-4444-555555555555",
  };

  test("marca privado e leva os metadados que o pipeline espera", () => {
    const p = buildPayload(base);
    expect(p.private).toBe(true);
    expect(p.slug).toBe("curso-de-espinosa-02-os-afetos");
    expect(p.duration_secs).toBe(3601);
    expect(p.json.metadata).toMatchObject({
      podcast: "Curso de Espinosa",
      title: "Os Afetos",
      published: "2026-11-09",
      duration: "01:00:01",
      source: "local",
      uuid: base.uuid,
    });
    expect(p.json.transcript).toBeNull();
    expect(p.json.metadata.author).toBeUndefined();
  });

  test("autor só entra quando informado", () => {
    expect(buildPayload({ ...base, author: "Thiago Silva" }).json.metadata.author).toBe("Thiago Silva");
  });
});
