-- Catálogo de Sistemas: inventário técnico de tudo que a mytek já
-- construiu (sites, apps, dashboards) — com propósito, stack, hospedagem,
-- diagrama C4 e histórico de alterações de cada um. Não é a mesma coisa
-- que "projects" (que são os projetos DE CLIENTE, com tarefas/portal/
-- faturas) — por isso tabela e tela separadas, pra não misturar os dois.
create table if not exists public.catalog_systems (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  subtitle text,
  purpose text,
  current_status text,
  status text not null default 'Em produção',
  category text not null default 'pessoal'
    check (category in ('no-ar', 'pessoal', 'clientes-mytek', 'projetos-mytek')),
  languages text[] not null default '{}',
  tools text[] not null default '{}',
  hosting jsonb not null default '[]',
  links jsonb not null default '[]',
  c4_svg text,
  local_path text,
  repo_url text,
  first_commit_date date,
  last_known_commit text,
  last_scan_at date,
  changelog jsonb not null default '[]',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.catalog_systems enable row level security;

-- Categoria "pessoal" só aparece pra quem criou. As outras três
-- (no-ar, clientes-mytek, projetos-mytek) são compartilhadas: qualquer
-- pessoa autenticada no Hub vê e edita, do mesmo jeito que já acontece
-- hoje com a tabela "projects".
create policy "select_catalog_systems"
  on public.catalog_systems for select
  to authenticated
  using (category <> 'pessoal' or created_by = auth.uid());

create policy "insert_catalog_systems"
  on public.catalog_systems for insert
  to authenticated
  with check (category <> 'pessoal' or created_by = auth.uid());

create policy "update_catalog_systems"
  on public.catalog_systems for update
  to authenticated
  using (category <> 'pessoal' or created_by = auth.uid())
  with check (category <> 'pessoal' or created_by = auth.uid());

create policy "delete_catalog_systems"
  on public.catalog_systems for delete
  to authenticated
  using (category <> 'pessoal' or created_by = auth.uid());

alter publication supabase_realtime add table public.catalog_systems;
