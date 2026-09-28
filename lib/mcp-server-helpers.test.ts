import { describe, it, expect, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  tarefaEhVisivel,
  urlDoApp,
  resolverProjeto,
  resolverResponsavel,
} from "./mcp-server-helpers";

// Fake mínimo do client do Supabase: cada método de filtro devolve o
// próprio builder (encadeável do jeito que o código real usa), e o
// builder é "thenable" (tem .then), então "await admin.from(...)...
// .order(...)" resolve pros dados configurados pra aquela tabela. Não
// reproduz o comportamento real dos filtros (.eq/.or/.ilike) — só serve
// pra testar a lógica de resolução das tools (nome parcial, ambiguidade,
// "eu"/"mim" etc.), não as regras de RLS/visibilidade do banco.
function makeAdmin(opts: {
  verTudo?: boolean;
  profiles?: Array<{ id: string; name: string; username: string | null }>;
  projects?: Array<{ id: string; name: string }>;
}): SupabaseClient {
  const { verTudo = false, profiles = [], projects = [] } = opts;

  return {
    from(table: string) {
      const builder: Record<string, unknown> = {
        select: () => builder,
        eq: () => builder,
        or: () => builder,
        not: () => builder,
        order: () => builder,
        limit: () => builder,
        ilike: () => builder,
        maybeSingle: () =>
          Promise.resolve(
            table === "profiles"
              ? { data: { ve_tudo: verTudo }, error: null }
              : { data: null, error: null }
          ),
        then: (
          resolve: (result: { data: unknown[]; error: null }) => void
        ) => {
          const rows =
            table === "profiles" ? profiles : table === "projects" ? projects : [];
          resolve({ data: rows, error: null });
        },
      };
      return builder;
    },
  } as unknown as SupabaseClient;
}

describe("tarefaEhVisivel", () => {
  const visiveis = new Set(["proj-1"]);

  it("tarefa dentro de um projeto visível é visível", () => {
    expect(
      tarefaEhVisivel(
        { project_id: "proj-1", created_by: "outro", assigned_to: [] },
        "eu",
        false,
        visiveis
      )
    ).toBe(true);
  });

  it("tarefa dentro de um projeto NÃO visível, sem ve_tudo, não é visível", () => {
    expect(
      tarefaEhVisivel(
        { project_id: "proj-2", created_by: "outro", assigned_to: [] },
        "eu",
        false,
        visiveis
      )
    ).toBe(false);
  });

  it("quem tem ve_tudo enxerga qualquer projeto", () => {
    expect(
      tarefaEhVisivel(
        { project_id: "proj-2", created_by: "outro", assigned_to: [] },
        "eu",
        true,
        visiveis
      )
    ).toBe(true);
  });

  it("tarefa sem projeto é visível pra quem criou", () => {
    expect(
      tarefaEhVisivel({ project_id: null, created_by: "eu", assigned_to: [] }, "eu", false, visiveis)
    ).toBe(true);
  });

  it("tarefa sem projeto é visível pra quem é responsável", () => {
    expect(
      tarefaEhVisivel(
        { project_id: null, created_by: "outro", assigned_to: ["eu"] },
        "eu",
        false,
        visiveis
      )
    ).toBe(true);
  });

  it("tarefa sem projeto, de outra pessoa, não é visível sem ve_tudo", () => {
    expect(
      tarefaEhVisivel(
        { project_id: null, created_by: "outro", assigned_to: ["outro"] },
        "eu",
        false,
        visiveis
      )
    ).toBe(false);
  });
});

describe("urlDoApp", () => {
  const originalEnv = process.env.NEXT_PUBLIC_SITE_URL;

  afterEach(() => {
    if (originalEnv === undefined) delete process.env.NEXT_PUBLIC_SITE_URL;
    else process.env.NEXT_PUBLIC_SITE_URL = originalEnv;
  });

  it("sem NEXT_PUBLIC_SITE_URL, devolve o caminho relativo", () => {
    delete process.env.NEXT_PUBLIC_SITE_URL;
    expect(urlDoApp("/board")).toBe("/board");
  });

  it("com NEXT_PUBLIC_SITE_URL, monta a url completa", () => {
    process.env.NEXT_PUBLIC_SITE_URL = "https://hub.mytek.com.br";
    expect(urlDoApp("/board")).toBe("https://hub.mytek.com.br/board");
  });

  it("remove a barra final da base antes de concatenar", () => {
    process.env.NEXT_PUBLIC_SITE_URL = "https://hub.mytek.com.br/";
    expect(urlDoApp("/board")).toBe("https://hub.mytek.com.br/board");
  });
});

describe("resolverProjeto", () => {
  const admin = makeAdmin({
    verTudo: true,
    projects: [
      { id: "p1", name: "Website da NDL" },
      { id: "p2", name: "Website da Ampla" },
      { id: "p3", name: "App Mobile" },
    ],
  });

  it("sem nome informado, tarefa vai pra Geral (sem projeto)", async () => {
    const resultado = await resolverProjeto(admin, "eu", undefined);
    expect(resultado).toEqual({ ok: true, projeto: null });
  });

  it("nome parcial e case-insensitive que bate um único projeto", async () => {
    const resultado = await resolverProjeto(admin, "eu", "ampla");
    expect(resultado).toEqual({ ok: true, projeto: { id: "p2", name: "Website da Ampla" } });
  });

  it("nome que não bate nenhum projeto retorna erro com a lista de disponíveis", async () => {
    const resultado = await resolverProjeto(admin, "eu", "Inexistente");
    expect(resultado.ok).toBe(false);
    if (!resultado.ok) {
      expect(resultado.erro).toContain("Website da NDL");
      expect(resultado.erro).toContain("App Mobile");
    }
  });

  it("nome ambíguo (bate mais de um projeto) retorna erro listando os candidatos", async () => {
    const resultado = await resolverProjeto(admin, "eu", "website");
    expect(resultado.ok).toBe(false);
    if (!resultado.ok) {
      expect(resultado.erro).toContain("Website da NDL");
      expect(resultado.erro).toContain("Website da Ampla");
    }
  });
});

describe("resolverResponsavel", () => {
  const admin = makeAdmin({
    profiles: [
      { id: "u1", name: "João Silva", username: "joao" },
      { id: "u2", name: "João Pedro", username: "jpedro" },
      { id: "u3", name: "Maria Souza", username: "maria" },
    ],
  });

  it("sem nome informado, não atribui ninguém", async () => {
    const resultado = await resolverResponsavel(admin, "u3", undefined);
    expect(resultado).toEqual({ ok: true, ids: [] });
  });

  it('"eu"/"mim" resolve pra quem está pedindo', async () => {
    expect(await resolverResponsavel(admin, "u3", "eu")).toEqual({ ok: true, ids: ["u3"] });
    expect(await resolverResponsavel(admin, "u3", "mim")).toEqual({ ok: true, ids: ["u3"] });
  });

  it("nome que bate uma única pessoa por username", async () => {
    const resultado = await resolverResponsavel(admin, "u3", "maria");
    expect(resultado).toEqual({ ok: true, ids: ["u3"] });
  });

  it("nome que não bate ninguém retorna erro", async () => {
    const resultado = await resolverResponsavel(admin, "u3", "Ninguém Com Esse Nome");
    expect(resultado.ok).toBe(false);
  });

  it("nome ambíguo (bate mais de uma pessoa) retorna erro", async () => {
    const resultado = await resolverResponsavel(admin, "u3", "joão");
    expect(resultado.ok).toBe(false);
    if (!resultado.ok) {
      expect(resultado.erro).toContain("João Silva");
      expect(resultado.erro).toContain("João Pedro");
    }
  });
});
