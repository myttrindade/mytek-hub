-- ===== 0001_init.sql =====
-- Habilita geração de UUID
create extension if not exists pgcrypto;

-- Status possíveis de uma tarefa
create type task_status as enum ('todo', 'doing', 'done');

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  status task_status not null default 'todo',
  position integer not null default 0,
  created_by uuid references auth.users(id) default auth.uid(),
  created_by_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Row Level Security: só quem está logado (qualquer pessoa do time) pode
-- ver e mexer nas tarefas. Todo mundo vê o mesmo quadro único da empresa.
alter table public.tasks enable row level security;

create policy "authenticated_select_tasks"
  on public.tasks for select
  to authenticated
  using (true);

create policy "authenticated_insert_tasks"
  on public.tasks for insert
  to authenticated
  with check (true);

create policy "authenticated_update_tasks"
  on public.tasks for update
  to authenticated
  using (true);

create policy "authenticated_delete_tasks"
  on public.tasks for delete
  to authenticated
  using (true);

-- Habilita atualizações em tempo real (para o quadro sincronizar entre
-- todo mundo que estiver logado ao mesmo tempo).
alter publication supabase_realtime add table public.tasks;

-- ===== 0002_pages.sql =====
-- Tabela da Wiki (páginas de texto rico, editor tipo Notion)
create table if not exists public.pages (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Sem título',
  content jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id) default auth.uid(),
  created_by_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Mesmo padrão de acesso do quadro de tarefas: qualquer pessoa logada da
-- empresa pode ver e editar qualquer página (wiki compartilhada única).
alter table public.pages enable row level security;

create policy "authenticated_select_pages"
  on public.pages for select
  to authenticated
  using (true);

create policy "authenticated_insert_pages"
  on public.pages for insert
  to authenticated
  with check (true);

create policy "authenticated_update_pages"
  on public.pages for update
  to authenticated
  using (true);

create policy "authenticated_delete_pages"
  on public.pages for delete
  to authenticated
  using (true);

-- Habilita atualizações em tempo real pra lista de páginas
alter publication supabase_realtime add table public.pages;

-- ===== 0003_messages.sql =====
-- Perfis públicos (nome/e-mail de cada pessoa), pra poder listar quem dá
-- pra mandar mensagem. auth.users não pode ser consultada direto pelo
-- app, então mantemos uma cópia simples aqui, preenchida automaticamente.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "authenticated_select_profiles"
  on public.profiles for select
  to authenticated
  using (true);

-- Cria o profile automaticamente sempre que alguém se cadastra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Preenche o profile de quem já tinha se cadastrado antes desta migration
insert into public.profiles (id, email)
select id, email from auth.users
on conflict (id) do nothing;

-- Mensagens diretas (1 pra 1) entre pessoas do time
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) default auth.uid(),
  recipient_id uuid not null references auth.users(id),
  content text not null,
  created_at timestamptz not null default now()
);

alter table public.messages enable row level security;

-- Só quem participa da conversa (remetente ou destinatário) consegue ver
create policy "select_own_messages"
  on public.messages for select
  to authenticated
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- Só dá pra mandar mensagem em seu próprio nome
create policy "insert_own_messages"
  on public.messages for insert
  to authenticated
  with check (auth.uid() = sender_id);

alter publication supabase_realtime add table public.messages;

-- ===== 0004_onboarding.sql =====
-- Nome e foto de cada pessoa (pra exibir em vez do e-mail cru)
alter table public.profiles add column if not exists name text;
alter table public.profiles add column if not exists avatar_url text;

-- Configuração única do "workspace" (nome da empresa/equipe). Só existe
-- uma linha (o sistema é de uma empresa só, não multi-empresa).
create table if not exists public.settings (
  id boolean primary key default true,
  workspace_name text,
  constraint settings_singleton check (id)
);

alter table public.settings enable row level security;

create policy "authenticated_select_settings"
  on public.settings for select
  to authenticated
  using (true);

create policy "authenticated_insert_settings"
  on public.settings for insert
  to authenticated
  with check (true);

create policy "authenticated_update_settings"
  on public.settings for update
  to authenticated
  using (true);

-- Bucket de Storage pra fotos de perfil (público pra leitura, cada pessoa
-- só pode escrever dentro da própria pasta "<seu-user-id>/...").
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "avatars_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'avatars');

create policy "avatars_owner_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_owner_update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ===== 0005_channels.sql =====
-- Canais de mensagens em grupo (além das mensagens diretas). Neste v1,
-- todo canal é aberto pra empresa toda (sem canais privados).
create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.channels enable row level security;

create policy "authenticated_select_channels"
  on public.channels for select
  to authenticated
  using (true);

create policy "authenticated_insert_channels"
  on public.channels for insert
  to authenticated
  with check (true);

alter publication supabase_realtime add table public.channels;

-- Uma mensagem passa a poder pertencer a um canal em vez de ser uma
-- mensagem direta. Toda mensagem tem OU recipient_id (DM) OU channel_id
-- (canal), nunca os dois.
alter table public.messages
  add column if not exists channel_id uuid references public.channels(id);

alter table public.messages
  alter column recipient_id drop not null;

alter table public.messages
  drop constraint if exists messages_dm_or_channel;

alter table public.messages
  add constraint messages_dm_or_channel
  check (
    (recipient_id is not null and channel_id is null)
    or (recipient_id is null and channel_id is not null)
  );

-- Mensagens de canal: qualquer pessoa logada pode ver (a política que já
-- existe cobre as mensagens diretas; esta cobre as de canal)
create policy "authenticated_select_channel_messages"
  on public.messages for select
  to authenticated
  using (channel_id is not null);

-- Cria um canal "geral" automaticamente se ainda não existir nenhum canal
insert into public.channels (name)
select 'geral'
where not exists (select 1 from public.channels);

-- ===== 0006_fix_profiles_update.sql =====
-- Faltava permissão de atualização na tabela profiles (só existia leitura),
-- por isso o onboarding não conseguia salvar o nome/foto da pessoa.
create policy "authenticated_update_own_profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- ===== 0007_username_login.sql =====
-- Login só com usuário e senha (sem e-mail). O Supabase Auth exige um
-- e-mail por baixo dos panos, então geramos um e-mail "sintético" a partir
-- do usuário (ex: usuário "erick" -> e-mail interno "erick@mytek-hub.internal").
-- Ninguém precisa saber, ver ou usar esse e-mail — ele nunca aparece na tela.

alter table public.profiles add column if not exists username text;

-- Formato básico: só letras minúsculas, números, ponto, underline e hífen.
alter table public.profiles drop constraint if exists profiles_username_format;
alter table public.profiles add constraint profiles_username_format
  check (username is null or username ~ '^[a-z0-9._-]{3,30}$');

-- Único (índice único trata múltiplos NULLs como distintos, então contas
-- antigas sem username não conflitam entre si).
create unique index if not exists profiles_username_key on public.profiles (username);

-- Ao criar a conta, guarda o username que veio junto no cadastro
-- (enviado como metadata no supabase.auth.signUp).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, username)
  values (new.id, new.email, new.raw_user_meta_data->>'username')
  on conflict (id) do nothing;
  return new;
end;
$$;

-- As colunas "created_by_email" nunca guardaram um e-mail de verdade pro
-- usuário final ver — agora que o login é por usuário, renomeia pra refletir
-- isso (vai passar a guardar o username de quem criou).
alter table public.tasks rename column created_by_email to created_by_label;
alter table public.pages rename column created_by_email to created_by_label;

-- ===== 0008_notifications.sql =====
-- Controla até quando cada pessoa já leu cada conversa (canal ou DM), pra
-- dar pra calcular quantas mensagens estão "não lidas" e mostrar o aviso.
create table if not exists public.message_reads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  -- Formato: 'channel:<id-do-canal>' ou 'dm:<id-da-outra-pessoa>'
  conversation_key text not null,
  last_read_at timestamptz not null default now(),
  unique (user_id, conversation_key)
);

alter table public.message_reads enable row level security;

create policy "own_message_reads_select"
  on public.message_reads for select
  to authenticated
  using (auth.uid() = user_id);

create policy "own_message_reads_insert"
  on public.message_reads for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "own_message_reads_update"
  on public.message_reads for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

alter publication supabase_realtime add table public.message_reads;

-- Marca como "já lido agora" todo canal existente pra todo mundo que já
-- tem conta, pra não inundar o mundo de "não lida" com o histórico antigo
-- assim que essa funcionalidade entrar no ar. Conversas diretas antigas
-- ficam de fora de propósito: só viram "lida" quando a pessoa abrir.
insert into public.message_reads (user_id, conversation_key, last_read_at)
select p.id, 'channel:' || c.id, now()
from public.profiles p
cross join public.channels c
on conflict (user_id, conversation_key) do nothing;

-- ===== 0009_calendar.sql =====
-- Data (prazo) opcional em cada tarefa. Quando preenchida, a tarefa passa
-- a aparecer automaticamente naquele dia no Calendário.
alter table public.tasks add column if not exists due_date date;

-- ===== 0010_task_color.sql =====
-- Cor escolhida pra tarefa (mostrada como uma tarja/bolinha colorida no
-- quadro e no calendário). Guarda só uma chave da paleta fixa do app.
alter table public.tasks add column if not exists color text;

alter table public.tasks drop constraint if exists tasks_color_valido;
alter table public.tasks add constraint tasks_color_valido
  check (
    color is null or color in
    ('gray', 'red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink')
  );

-- ===== 0011_task_wiki_link.sql =====
-- Liga uma tarefa a uma página da Wiki, que funciona como uma versão mais
-- detalhada dela (texto rico, checklist, links etc). Se a página for
-- apagada, a tarefa só perde o vínculo, não é afetada.
alter table public.tasks
  add column if not exists page_id uuid references public.pages(id) on delete set null;

-- ===== 0012_projects.sql =====
-- Projetos: cada um tem seu próprio quadro de tarefas e sua própria lista
-- de páginas da Wiki, isolados dos outros. Tarefas/páginas sem projeto
-- continuam aparecendo no quadro/wiki "Geral" de sempre.
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.projects enable row level security;

create policy "authenticated_select_projects"
  on public.projects for select
  to authenticated
  using (true);

create policy "authenticated_insert_projects"
  on public.projects for insert
  to authenticated
  with check (true);

create policy "authenticated_delete_projects"
  on public.projects for delete
  to authenticated
  using (true);

alter publication supabase_realtime add table public.projects;

-- Liga tarefa/página a um projeto (opcional). Se o projeto for apagado,
-- elas não somem — só voltam a aparecer no quadro/wiki "Geral"
-- (por isso "on delete set null", não cascade).
alter table public.tasks
  add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table public.pages
  add column if not exists project_id uuid references public.projects(id) on delete set null;

-- ===== 0013_task_details.sql =====
-- Campos extras da tarefa: descrição, horário, recorrência e responsável.
-- O status ganha um 4º valor possível: "cancelled" (a coluna já é texto
-- livre, sem enum no banco — a validação fica só no front).
alter table public.tasks
  add column if not exists description text,
  add column if not exists due_time time,
  add column if not exists repeat_rule text not null default 'none'
    check (repeat_rule in ('none', 'daily', 'weekly', 'monthly')),
  add column if not exists assigned_to uuid references public.profiles(id) on delete set null;

-- Checklist (subtarefas) de cada tarefa.
create table if not exists public.task_checklist_items (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  title text not null,
  done boolean not null default false,
  position integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.task_checklist_items enable row level security;
create policy "authenticated_all_checklist"
  on public.task_checklist_items for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.task_checklist_items;

-- Comentários dentro da tarefa.
create table if not exists public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  content text not null,
  created_by_label text,
  created_at timestamptz not null default now()
);
alter table public.task_comments enable row level security;
create policy "authenticated_all_task_comments"
  on public.task_comments for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.task_comments;

-- Anexos (arquivos) da tarefa — o arquivo em si fica no Storage, aqui só
-- guardamos a referência.
create table if not exists public.task_attachments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  file_name text not null,
  file_path text not null,
  uploaded_by_label text,
  created_at timestamptz not null default now()
);
alter table public.task_attachments enable row level security;
create policy "authenticated_all_task_attachments"
  on public.task_attachments for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.task_attachments;

insert into storage.buckets (id, name, public)
values ('task-attachments', 'task-attachments', true)
on conflict (id) do nothing;

create policy "authenticated_all_task_attachments_storage"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'task-attachments')
  with check (bucket_id = 'task-attachments');

-- Registro de horas trabalhadas em cada tarefa.
create table if not exists public.task_hours (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  hours numeric not null check (hours > 0),
  note text,
  created_by_label text,
  created_at timestamptz not null default now()
);
alter table public.task_hours enable row level security;
create policy "authenticated_all_task_hours"
  on public.task_hours for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.task_hours;

-- ===== 0014_drive.sql =====
-- "Drive" de arquivos, com pastas — organizado por cliente (ou "Geral",
-- quando client_id é nulo). É um cadastro novo, independente dos Projetos.
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.clients enable row level security;
create policy "authenticated_all_clients"
  on public.clients for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.clients;

-- Pastas podem ser aninhadas (parent_folder_id aponta pra outra pasta).
-- Apagar uma pasta apaga o que tem dentro dela (subpastas e arquivos),
-- do jeito que se espera de um gerenciador de arquivos comum.
create table if not exists public.drive_folders (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  client_id uuid references public.clients(id) on delete set null,
  parent_folder_id uuid references public.drive_folders(id) on delete cascade,
  created_by_label text,
  created_at timestamptz not null default now()
);
alter table public.drive_folders enable row level security;
create policy "authenticated_all_drive_folders"
  on public.drive_folders for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.drive_folders;

-- O arquivo em si fica no Storage, aqui só a referência. Se apagar o
-- cliente, os arquivos não somem — só voltam pro Drive "Geral".
create table if not exists public.drive_files (
  id uuid primary key default gen_random_uuid(),
  folder_id uuid references public.drive_folders(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  file_name text not null,
  file_path text not null,
  file_size bigint,
  uploaded_by_label text,
  created_at timestamptz not null default now()
);
alter table public.drive_files enable row level security;
create policy "authenticated_all_drive_files"
  on public.drive_files for all
  to authenticated using (true) with check (true);
alter publication supabase_realtime add table public.drive_files;

insert into storage.buckets (id, name, public)
values ('drive-files', 'drive-files', true)
on conflict (id) do nothing;

create policy "authenticated_all_drive_files_storage"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'drive-files')
  with check (bucket_id = 'drive-files');

-- ===== 0015_drive_private.sql =====
-- Adiciona "Meus arquivos" (privado) x "Compartilhados" no Drive "Geral"
-- (raiz). owner_id nulo = compartilhado, todo mundo vê (como já era).
-- owner_id preenchido = privado, só quem criou consegue ver ou mexer.
alter table public.drive_folders
  add column if not exists owner_id uuid references auth.users(id) on delete cascade;
alter table public.drive_files
  add column if not exists owner_id uuid references auth.users(id) on delete cascade;

-- As políticas antigas liberavam tudo pra todo mundo — trocamos por
-- políticas que checam o dono quando o item é privado.
drop policy if exists "authenticated_all_drive_folders" on public.drive_folders;
drop policy if exists "authenticated_all_drive_files" on public.drive_files;

create policy "drive_folders_select" on public.drive_folders for select
  to authenticated using (owner_id is null or owner_id = auth.uid());
create policy "drive_folders_insert" on public.drive_folders for insert
  to authenticated with check (owner_id is null or owner_id = auth.uid());
create policy "drive_folders_update" on public.drive_folders for update
  to authenticated
  using (owner_id is null or owner_id = auth.uid())
  with check (owner_id is null or owner_id = auth.uid());
create policy "drive_folders_delete" on public.drive_folders for delete
  to authenticated using (owner_id is null or owner_id = auth.uid());

create policy "drive_files_select" on public.drive_files for select
  to authenticated using (owner_id is null or owner_id = auth.uid());
create policy "drive_files_insert" on public.drive_files for insert
  to authenticated with check (owner_id is null or owner_id = auth.uid());
create policy "drive_files_update" on public.drive_files for update
  to authenticated
  using (owner_id is null or owner_id = auth.uid())
  with check (owner_id is null or owner_id = auth.uid());
create policy "drive_files_delete" on public.drive_files for delete
  to authenticated using (owner_id is null or owner_id = auth.uid());

-- Bucket separado, de verdade privado, só pros arquivos de "Meus
-- arquivos". O bucket "drive-files" (Compartilhados + clientes) continua
-- público, sem nenhuma mudança.
insert into storage.buckets (id, name, public)
values ('drive-files-private', 'drive-files-private', false)
on conflict (id) do nothing;

-- Cada arquivo privado é salvo com o id do dono como primeira pasta do
-- caminho (ex: "<uid>/raiz/123-arquivo.pdf") — essa política só deixa
-- cada pessoa mexer na própria pasta dentro do bucket privado.
create policy "drive_files_private_storage_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'drive-files-private'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "drive_files_private_storage_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'drive-files-private'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "drive_files_private_storage_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'drive-files-private'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ===== 0016_task_requests.sql =====
-- "Solicitação de tarefa": alguém pede uma tarefa pra outra pessoa, e ela
-- fica pendente até a pessoa aceitar (vira tarefa de verdade no quadro,
-- atribuída a quem aceitou) ou recusar.
create table if not exists public.task_requests (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  project_id uuid references public.projects(id) on delete set null,
  requested_by uuid references auth.users(id) default auth.uid(),
  requested_by_label text,
  requested_to uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  -- Preenchido quando aceita: aponta pra tarefa criada a partir do pedido.
  task_id uuid references public.tasks(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

alter table public.task_requests enable row level security;

-- Segue o mesmo padrão do resto do sistema: qualquer pessoa logada do time
-- vê e mexe (não é informação sensível, é só um pedido de trabalho).
create policy "authenticated_all_task_requests"
  on public.task_requests for all
  to authenticated using (true) with check (true);

alter publication supabase_realtime add table public.task_requests;

-- ===== 0017_fix_task_status_cancelled.sql =====
-- Corrige um problema pendente: a tela já deixa marcar uma tarefa como
-- "Cancelada", mas a coluna "status" no banco ainda era um enum só com
-- ('todo', 'doing', 'done') — salvar "cancelled" ia dar erro. Troca pra
-- texto livre (com uma trava garantindo só esses 4 valores).
alter table public.tasks alter column status drop default;
alter table public.tasks alter column status type text using status::text;
alter table public.tasks alter column status set default 'todo';
alter table public.tasks add constraint tasks_status_valido
  check (status in ('todo', 'doing', 'done', 'cancelled'));
drop type if exists task_status;

-- ===== 0018_project_progress_share.sql =====
-- Link público de progresso do projeto, pra mandar pro cliente. Cada
-- projeto ganha um token (código difícil de adivinhar) — quem tem o link
-- "https://.../progresso/<token>" vê um resumo básico, sem precisar de
-- login. "Gerar novo link" (trocar o token) invalida o link antigo.
alter table public.projects
  add column if not exists share_token uuid not null default gen_random_uuid();

-- Função que devolve só o essencial (nome do projeto, contagem por status e
-- a lista de tarefas com título/status/data — sem descrição, comentários,
-- responsável, horas ou qualquer outra coisa interna). É "security definer"
-- de propósito: assim a pessoa anônima (sem login) só precisa ter permissão
-- pra CHAMAR essa função — ela não ganha acesso direto às tabelas de
-- projetos/tarefas, só ao que a função decide devolver.
create or replace function public.get_project_progress(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id, name into projeto
  from public.projects
  where share_token = p_token;

  if not found then
    return null;
  end if;

  select json_build_object(
    'project_name', projeto.name,
    'total', count(*) filter (where t.status <> 'cancelled'),
    'concluidas', count(*) filter (where t.status = 'done'),
    'andamento', count(*) filter (where t.status = 'doing'),
    'abertas', count(*) filter (where t.status = 'todo'),
    'canceladas', count(*) filter (where t.status = 'cancelled'),
    'tasks', coalesce(
      json_agg(
        json_build_object(
          'id', t.id,
          'title', t.title,
          'status', t.status,
          'due_date', t.due_date
        )
        order by t.position
      ) filter (where t.status <> 'cancelled'),
      '[]'::json
    )
  )
  into resultado
  from public.tasks t
  where t.project_id = projeto.id;

  return resultado;
end;
$$;

-- Qualquer um (mesmo sem login) pode CHAMAR a função — não é a mesma coisa
-- que liberar select direto nas tabelas. A segurança tá em precisar saber o
-- token certo (só quem tem o link).
grant execute on function public.get_project_progress(uuid) to anon, authenticated;

-- ===== 0019_task_requests_extra_fields.sql =====
-- Campos extras no formulário de solicitação de tarefa, pra ficar parecido
-- com o formulário "Solicitação Marketing" que a Now já usa em outro lugar:
-- tipo de demanda, empresa, telefone, status, urgência, data de entrega e
-- link do drive. A partir de agora a solicitação também não fica mais
-- "pendente" esperando alguém aceitar ou recusar — ao enviar, a tarefa já é
-- criada na hora (ver components/TaskRequests.tsx).
alter table public.task_requests
  add column if not exists client_id uuid references public.clients(id) on delete set null,
  add column if not exists demand_type text,
  add column if not exists phone text,
  add column if not exists context_status text,
  add column if not exists urgency text,
  add column if not exists due_date date,
  add column if not exists drive_url text;

-- ===== 0020_task_multiple_assignees.sql =====
-- Permite mais de uma pessoa responsável pela mesma tarefa: troca
-- "assigned_to" de um único uuid pra uma lista (array) de uuids. Quem já
-- tinha um responsável definido continua com essa pessoa na lista — ninguém
-- perde o que já estava atribuído.
alter table public.tasks
  drop constraint if exists tasks_assigned_to_fkey;

alter table public.tasks
  alter column assigned_to type uuid[]
  using (case when assigned_to is null then '{}'::uuid[] else array[assigned_to] end);

alter table public.tasks
  alter column assigned_to set default '{}'::uuid[];

alter table public.tasks
  alter column assigned_to set not null;

-- Índice pra filtrar rápido "tarefas onde eu sou um dos responsáveis"
-- (usado no quadro/calendário/wiki/projetos individuais de cada um).
create index if not exists tasks_assigned_to_gin on public.tasks using gin (assigned_to);

-- ===== 0021_profile_ve_tudo.sql =====
-- Algumas poucas pessoas enxergam as tarefas/calendário/wiki/projetos de
-- todo mundo, não só as próprias (hoje: só a Emily). Mensagens continuam
-- sempre privadas pra todo mundo, sem exceção nenhuma — essa coluna não
-- mexe em chat.
alter table public.profiles
  add column if not exists ve_tudo boolean not null default false;

update public.profiles set ve_tudo = true where username = 'emily';

-- Pra dar esse acesso pra mais alguém no futuro, basta rodar:
-- update public.profiles set ve_tudo = true where username = 'usuario-da-pessoa';

-- ===== 0022_project_created_by_label.sql =====
-- Mesmo padrão de tasks/pages: guarda o nome/usuário de quem criou o
-- projeto direto na linha, pra mostrar no card sem precisar de join.
alter table public.projects add column if not exists created_by_label text;

-- Preenche os projetos que já existem, usando o profile de quem criou.
update public.projects p
set created_by_label = coalesce(pr.name, pr.username)
from public.profiles pr
where p.created_by = pr.id
  and p.created_by_label is null;

-- ===== 0023_files_in_projects.sql =====
-- Cliente e Projeto viram a mesma coisa: os arquivos de um cliente passam a
-- viver dentro do projeto dele (cada projeto = um cliente), em vez de numa
-- área central separada. Não é destrutivo: a tabela clients e as colunas
-- client_id continuam existindo do jeito que estavam (só deixam de ser
-- usadas pelo app a partir daqui) — dá pra conferir/reverter se precisar.
--
-- O que essa migração faz:
--   1) Adiciona project_id em drive_folders e drive_files, no mesmo padrão
--      de tasks.project_id / pages.project_id (nullable, on delete set
--      null — se o projeto for apagado, o arquivo não some, só perde o
--      vínculo).
--   2) Pra cada cliente que já existe, procura um projeto com o mesmo nome
--      (ignorando maiúsculas/minúsculas e espaços nas pontas) — se não
--      achar, cria um projeto novo com esse nome. Isso cobre o caso comum
--      de já existir um projeto "Empresa X" e um cliente "Empresa X": os
--      dois viram o mesmo projeto, em vez de duplicar.
--   3) Repõe project_id em toda pasta/arquivo/solicitação que já tinha
--      client_id, apontando pro projeto resolvido no passo 2.

alter table public.drive_folders
  add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table public.drive_files
  add column if not exists project_id uuid references public.projects(id) on delete set null;

-- 2) Cria um projeto pra cada cliente que ainda não tem um projeto
--    "equivalente" (mesmo nome, comparação sem diferenciar
--    maiúsculas/minúsculas nem espaços nas pontas).
insert into public.projects (name, created_by, created_by_label, created_at)
select c.name, c.created_by, coalesce(pr.name, pr.username), c.created_at
from public.clients c
left join public.profiles pr on pr.id = c.created_by
where not exists (
  select 1 from public.projects p
  where trim(lower(p.name)) = trim(lower(c.name))
);

-- 3) Repõe project_id em quem já tinha client_id, usando o mesmo casamento
--    por nome do passo 2. O "project_id is null" garante que, se essa
--    migração rodar de novo, nada que já foi resolvido é sobrescrito (e no
--    caso de task_requests, também não mexe em quem já tinha um projeto
--    escolhido diretamente no formulário).
update public.drive_folders df
set project_id = p.id
from public.clients c
join public.projects p on trim(lower(p.name)) = trim(lower(c.name))
where df.client_id = c.id
  and df.project_id is null;

update public.drive_files dfl
set project_id = p.id
from public.clients c
join public.projects p on trim(lower(p.name)) = trim(lower(c.name))
where dfl.client_id = c.id
  and dfl.project_id is null;

update public.task_requests tr
set project_id = p.id
from public.clients c
join public.projects p on trim(lower(p.name)) = trim(lower(c.name))
where tr.client_id = c.id
  and tr.project_id is null;

-- ===== 0024_cleanup_duplicate_projects.sql =====
-- Limpeza dos projetos duplicados que a migração 0023 criou sem querer:
-- quando um cliente tinha o mesmo nome de um projeto já existente, mas
-- escrito com letras diferentes (ex: "Giordano" vs "GIORDANO"), ou quando
-- havia dois clientes com o nome exatamente igual, a checagem "já existe
-- um projeto com esse nome?" não enxergava o outro registro que estava
-- sendo inserido na mesma leva — resultado: projeto duplicado.
--
-- O que esse script faz:
--   1) Para cada grupo de projetos com o mesmo nome (comparação sem
--      diferenciar maiúsculas/minúsculas), escolhe quem fica: prefere a
--      versão que não está toda em maiúsculas (o "nome bonito"); em caso
--      de empate, fica o mais antigo. Reaponta tasks/pages/drive_folders/
--      drive_files/task_requests do(s) duplicado(s) pro escolhido, e
--      apaga o(s) duplicado(s).
--   2) Junta "ADG" dentro de "ADG Advogados" (nomes diferentes, mas é o
--      mesmo cliente) do mesmo jeito.
--   3) Apaga "projeto2" só se estiver realmente vazio (sem nenhuma tarefa,
--      página, pasta, arquivo ou solicitação linkada) — se tiver algo
--      dentro, não mexe e avisa no final pra conferir manualmente.
--
-- Seguro rodar mais de uma vez: depois de limpo, não sobra duplicata nem
-- "ADG"/"projeto2" pra mexer de novo.

do $$
declare
  grupo record;
  vencedor uuid;
  perdedor uuid;
  id_projeto2 uuid;
  tem_dados boolean;
  i int;
begin
  -- 1) Duplicatas por nome.
  for grupo in
    select array_agg(id order by (name = upper(name)) asc, created_at asc) as ids
    from public.projects
    group by trim(lower(name))
    having count(*) > 1
  loop
    vencedor := grupo.ids[1];
    for i in 2..array_length(grupo.ids, 1) loop
      perdedor := grupo.ids[i];

      update public.tasks set project_id = vencedor where project_id = perdedor;
      update public.pages set project_id = vencedor where project_id = perdedor;
      update public.drive_folders set project_id = vencedor where project_id = perdedor;
      update public.drive_files set project_id = vencedor where project_id = perdedor;
      update public.task_requests set project_id = vencedor where project_id = perdedor;

      delete from public.projects where id = perdedor;
    end loop;
  end loop;

  -- 2) "ADG" -> "ADG Advogados".
  select id into vencedor from public.projects where trim(name) = 'ADG Advogados' limit 1;
  select id into perdedor from public.projects where trim(name) = 'ADG' limit 1;
  if vencedor is not null and perdedor is not null and vencedor <> perdedor then
    update public.tasks set project_id = vencedor where project_id = perdedor;
    update public.pages set project_id = vencedor where project_id = perdedor;
    update public.drive_folders set project_id = vencedor where project_id = perdedor;
    update public.drive_files set project_id = vencedor where project_id = perdedor;
    update public.task_requests set project_id = vencedor where project_id = perdedor;
    delete from public.projects where id = perdedor;
  end if;

  -- 3) "projeto2": apaga só se estiver vazio.
  select id into id_projeto2 from public.projects where trim(name) = 'projeto2' limit 1;
  if id_projeto2 is not null then
    select exists(
      select 1 from public.tasks where project_id = id_projeto2
      union all select 1 from public.pages where project_id = id_projeto2
      union all select 1 from public.drive_folders where project_id = id_projeto2
      union all select 1 from public.drive_files where project_id = id_projeto2
      union all select 1 from public.task_requests where project_id = id_projeto2
    ) into tem_dados;

    if not tem_dados then
      delete from public.projects where id = id_projeto2;
    else
      raise notice 'projeto2 tem tarefas/páginas/arquivos dentro — não apaguei, confere manualmente.';
    end if;
  end if;
end $$;

-- ===== 0025_cleanup_duplicate_projects_2.sql =====
-- Ficou uma dupla ainda ("Chloe Semi Joias" 2x) depois da 0024 — a causa
-- mais provável é espaço duplo/sobrando no MEIO do nome (a 0024 só tirava
-- espaço das pontas com trim(), não normalizava espaço interno). Esse
-- script repete a mesma lógica de fusão, só que agora colapsando qualquer
-- sequência de espaços em um só antes de comparar. Seguro rodar de novo
-- mesmo se não sobrar nada pra fundir.

do $$
declare
  grupo record;
  vencedor uuid;
  perdedor uuid;
  i int;
begin
  for grupo in
    select array_agg(id order by (name = upper(name)) asc, created_at asc) as ids
    from public.projects
    group by lower(regexp_replace(trim(name), '\s+', ' ', 'g'))
    having count(*) > 1
  loop
    vencedor := grupo.ids[1];
    for i in 2..array_length(grupo.ids, 1) loop
      perdedor := grupo.ids[i];

      update public.tasks set project_id = vencedor where project_id = perdedor;
      update public.pages set project_id = vencedor where project_id = perdedor;
      update public.drive_folders set project_id = vencedor where project_id = perdedor;
      update public.drive_files set project_id = vencedor where project_id = perdedor;
      update public.task_requests set project_id = vencedor where project_id = perdedor;

      delete from public.projects where id = perdedor;
    end loop;
  end loop;
end $$;

-- ===== 0026_project_public.sql =====
-- Projeto público: quem não é dono e não tem tarefa nele também consegue
-- ver (usado pros projetos que são, na prática, clientes da empresa).
-- Todo projeto nasce privado (false) — só vira público quem marcar
-- manualmente pelo menu "⋮" na tela de Projetos.
alter table public.projects
  add column if not exists is_public boolean not null default false;

-- A tabela nunca teve uma policy de UPDATE (só select/insert/delete) —
-- sem isso, tanto "Editar" (renomear) quanto o novo "Tornar público" não
-- conseguem gravar nada, mesmo sem dar erro (RLS barra silenciosamente).
drop policy if exists "authenticated_update_projects" on public.projects;
create policy "authenticated_update_projects"
  on public.projects for update
  to authenticated
  using (true)
  with check (true);

-- Marca como público os 10 projetos que são clientes da empresa.
update public.projects
set is_public = true
where trim(name) in (
  'ADG Advogados',
  'CAROLINA MACHADO',
  'CHLOE SEMI JOIAS',
  'Giordano',
  'Iphone Litoral',
  'JOG Corp',
  'JORNADA 4S',
  'NDL',
  'NLG COMEX',
  'Won Oficial'
);

-- ===== 0027_client_onboarding.sql =====
-- Onboarding do cliente: 5 etapas fixas que o cliente preenche na própria
-- página pública de progresso (/progresso/<token>), antes do projeto
-- "começar" de verdade — informações da empresa, objetivos, escopo,
-- participantes e aprovação final. Cada etapa é uma linha aqui: nasce
-- "pending" (nem precisa existir a linha — ver função abaixo), guarda o
-- que o cliente preencheu em "payload" (formato livre, depende da etapa)
-- e vira "completed" quando ele confirma.
create table if not exists public.project_onboarding_steps (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  step_key text not null check (
    step_key in ('company_info', 'objectives', 'scope', 'participants', 'approval')
  ),
  status text not null default 'pending' check (
    status in ('pending', 'in_progress', 'completed')
  ),
  payload jsonb not null default '{}'::jsonb,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (project_id, step_key)
);

alter table public.project_onboarding_steps enable row level security;

-- Uso interno (equipe logada), mesmo padrão simples do resto do sistema —
-- todo autenticado lê/edita tudo. O cliente (sem login) nunca acessa essa
-- tabela direto: só através das funções abaixo, "security definer" e
-- travadas pelo share_token — mesmo padrão de get_project_progress
-- (migration 0018_project_progress_share.sql).
create policy "authenticated_all_onboarding_steps"
  on public.project_onboarding_steps for all
  to authenticated
  using (true)
  with check (true);

alter publication supabase_realtime add table public.project_onboarding_steps;

-- Devolve o estado do onboarding: as 5 etapas sempre nessa ordem (mesmo
-- que ainda não exista nenhuma linha criada pro projeto = todas
-- "pending"), os dados básicos do projeto e a contagem de tarefas — tudo
-- numa chamada só, pra alimentar a página pública inteira.
create or replace function public.get_project_onboarding(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id, name into projeto
  from public.projects
  where share_token = p_token;

  if not found then
    return null;
  end if;

  select json_build_object(
    'project_id', projeto.id,
    'project_name', projeto.name,
    'steps', (
      select coalesce(json_agg(
        json_build_object(
          'step_key', etapas.chave,
          'status', coalesce(s.status, 'pending'),
          'payload', coalesce(s.payload, '{}'::jsonb),
          'completed_at', s.completed_at
        )
        order by etapas.ordem
      ), '[]'::json)
      from (values
        ('company_info', 1),
        ('objectives', 2),
        ('scope', 3),
        ('participants', 4),
        ('approval', 5)
      ) as etapas(chave, ordem)
      left join public.project_onboarding_steps s
        on s.project_id = projeto.id and s.step_key = etapas.chave
    ),
    'tasks', (
      select coalesce(json_agg(
        json_build_object(
          'id', t.id,
          'title', t.title,
          'status', t.status,
          'due_date', t.due_date
        )
        order by t.position
      ) filter (where t.status <> 'cancelled'), '[]'::json)
      from public.tasks t
      where t.project_id = projeto.id
    ),
    'progress', (
      select json_build_object(
        'total', count(*) filter (where t.status <> 'cancelled'),
        'concluidas', count(*) filter (where t.status = 'done'),
        'andamento', count(*) filter (where t.status = 'doing'),
        'abertas', count(*) filter (where t.status = 'todo')
      )
      from public.tasks t
      where t.project_id = projeto.id
    )
  )
  into resultado;

  return resultado;
end;
$$;

grant execute on function public.get_project_onboarding(uuid) to anon, authenticated;

-- Salva/atualiza uma etapa do onboarding. "p_complete = true" marca como
-- concluída (grava completed_at); "false" guarda o progresso mas deixa
-- "in_progress" (rascunho, ainda dá pra editar depois). Só deixa
-- concluir uma etapa se a anterior já estiver concluída — mesma trava
-- mostrada na tela (etapa "locked"), garantida aqui também pra ninguém
-- pular etapa direto chamando a função.
create or replace function public.save_onboarding_step(
  p_token uuid,
  p_step text,
  p_payload jsonb,
  p_complete boolean default true
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  ordem_atual int;
  etapa_anterior text;
  status_anterior text;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    raise exception 'link inválido';
  end if;

  select ordem into ordem_atual
  from (values
    ('company_info', 1), ('objectives', 2), ('scope', 3),
    ('participants', 4), ('approval', 5)
  ) as etapas(chave, ordem)
  where chave = p_step;

  if ordem_atual is null then
    raise exception 'etapa inválida';
  end if;

  if p_complete and ordem_atual > 1 then
    select chave into etapa_anterior
    from (values
      ('company_info', 1), ('objectives', 2), ('scope', 3),
      ('participants', 4), ('approval', 5)
    ) as etapas(chave, ordem)
    where ordem = ordem_atual - 1;

    select status into status_anterior
    from public.project_onboarding_steps
    where project_id = projeto.id and step_key = etapa_anterior;

    if coalesce(status_anterior, 'pending') <> 'completed' then
      raise exception 'conclua a etapa anterior primeiro';
    end if;
  end if;

  insert into public.project_onboarding_steps (project_id, step_key, status, payload, completed_at)
  values (
    projeto.id,
    p_step,
    case when p_complete then 'completed' else 'in_progress' end,
    p_payload,
    case when p_complete then now() else null end
  )
  on conflict (project_id, step_key) do update
  set status = excluded.status,
      payload = excluded.payload,
      completed_at = excluded.completed_at,
      updated_at = now();

  return public.get_project_onboarding(p_token);
end;
$$;

grant execute on function public.save_onboarding_step(uuid, text, jsonb, boolean) to anon, authenticated;

-- ===== 0028_client_documents.sql =====
-- Devolve os documentos COMPARTILHADOS (não-privados) de um projeto, pra
-- mostrar na página pública /progresso/<token> — mesmo padrão de
-- segurança de get_project_progress (migration 0018): função
-- "security definer" travada pelo token, o cliente (sem login) nunca
-- acessa drive_folders/drive_files direto.
--
-- Só pega pastas de primeiro nível do projeto (parent_folder_id nulo) e
-- os arquivos delas + os arquivos soltos na raiz — não desce em
-- subpastas aninhadas. Arquivos/pastas privados (owner_id preenchido,
-- ex: "Meus arquivos" de alguém da equipe) nunca aparecem aqui.
create or replace function public.get_project_documents(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    return null;
  end if;

  select json_build_object(
    'folders', (
      select coalesce(json_agg(
        json_build_object('id', f.id, 'name', f.name)
        order by f.name
      ), '[]'::json)
      from public.drive_folders f
      where f.project_id = projeto.id
        and f.parent_folder_id is null
        and f.owner_id is null
    ),
    'files', (
      select coalesce(json_agg(
        json_build_object(
          'id', fl.id,
          'folder_id', fl.folder_id,
          'file_name', fl.file_name,
          'file_path', fl.file_path,
          'file_size', fl.file_size,
          'created_at', fl.created_at
        )
        order by fl.file_name
      ), '[]'::json)
      from public.drive_files fl
      where fl.project_id = projeto.id
        and fl.owner_id is null
        and (
          fl.folder_id is null
          or fl.folder_id in (
            select id from public.drive_folders
            where project_id = projeto.id
              and parent_folder_id is null
              and owner_id is null
          )
        )
    )
  )
  into resultado;

  return resultado;
end;
$$;

grant execute on function public.get_project_documents(uuid) to anon, authenticated;

-- ===== 0029_client_invoices.sql =====
-- Faturas de um projeto — cadastradas pela equipe (aba "Faturas" dentro
-- de /projetos/[id]) e mostradas pro cliente, só leitura, na aba
-- "Faturas" da página pública /progresso/<token>.
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  description text not null,
  amount numeric(12, 2) not null,
  due_date date not null,
  -- "overdue" (vencida) não é gravado aqui — é calculado na hora (ver
  -- lib/invoices.ts) comparando due_date com a data de hoje, pra uma
  -- fatura "pending" não precisar de um job agendado pra virar vencida.
  status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled')),
  paid_at timestamptz,
  -- Opcional: o PDF/boleto da fatura, se a equipe anexar um.
  file_path text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_by_label text,
  created_at timestamptz not null default now()
);

alter table public.invoices enable row level security;

create policy "authenticated_all_invoices"
  on public.invoices for all
  to authenticated
  using (true)
  with check (true);

alter publication supabase_realtime add table public.invoices;

-- Bucket público (mesmo esquema do "drive-files") — o link do PDF vai
-- direto pro cliente, sem precisar de sessão.
insert into storage.buckets (id, name, public)
values ('invoices', 'invoices', true)
on conflict (id) do nothing;

create policy "authenticated_all_invoices_storage"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'invoices')
  with check (bucket_id = 'invoices');

-- Devolve as faturas de um projeto pro cliente (só leitura), travado
-- pelo share_token — mesmo padrão de segurança de get_project_progress
-- e get_project_documents.
create or replace function public.get_project_invoices(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    return null;
  end if;

  select coalesce(json_agg(
    json_build_object(
      'id', i.id,
      'description', i.description,
      'amount', i.amount,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'file_path', i.file_path
    )
    order by i.due_date desc
  ), '[]'::json)
  into resultado
  from public.invoices i
  where i.project_id = projeto.id;

  return resultado;
end;
$$;

grant execute on function public.get_project_invoices(uuid) to anon, authenticated;

-- ===== 0030_client_portal.sql =====
-- Portal do cliente (Visão geral) — campos novos no projeto, notificações,
-- mensagens e avaliação do cliente. Tudo com dado real: nada aqui é
-- "enfeite" — cada pedaço da tela nova em /progresso/<token> lê algo que
-- a equipe realmente preencheu ou que aconteceu de verdade no sistema.

-- 1) Dados do projeto usados no card "Seu projeto" e na etapa/stepper.
-- Nascem com um valor padrão (todo projeto começa em "planejamento") — a
-- equipe ajusta pela tela interna (ProjectDetailsCard, em /projetos/[id]).
alter table public.projects
  add column if not exists status text not null default 'planejamento'
    check (status in ('planejamento', 'execucao', 'revisao', 'concluido')),
  add column if not exists responsible_id uuid references auth.users(id),
  add column if not exists responsible_label text,
  add column if not exists start_date date,
  add column if not exists target_end_date date,
  -- Item manual do checklist ("Responder informações iniciais") — não tem
  -- como calcular sozinho, então é a equipe quem marca depois de alinhar
  -- com o cliente por fora (telefone, reunião, WhatsApp etc).
  add column if not exists initial_info_confirmed boolean not null default false;

-- 2) Feed de notificações/atividades do projeto — alimentado só por
-- gatilhos (nunca por texto solto da equipe), pra ficar 100% real: cada
-- linha aqui é um evento que de fato aconteceu (documento, fatura, tarefa,
-- etapa, mensagem). Serve tanto pro sino de notificações quanto pro
-- "Histórico de atividades" (mesma tabela, duas visualizações).
create table if not exists public.project_notifications (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  type text not null check (type in ('document', 'invoice', 'task', 'task_done', 'message', 'status')),
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);

alter table public.project_notifications enable row level security;

create policy "authenticated_select_project_notifications"
  on public.project_notifications for select
  to authenticated
  using (true);

-- 3) Mensagens entre a equipe e o cliente (aba "Mensagens" em
-- /projetos/[id] pra equipe; card "Comunicação do projeto" no link
-- público pro cliente). Cliente não tem login, então "sender_label" é
-- livre (o nome que a pessoa digitar) — sem isso não tem como saber quem
-- é quem do lado do cliente.
create table if not exists public.project_messages (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  sender_type text not null check (sender_type in ('team', 'client')),
  sender_label text not null,
  content text not null,
  created_at timestamptz not null default now()
);

alter table public.project_messages enable row level security;

create policy "authenticated_all_project_messages"
  on public.project_messages for all
  to authenticated
  using (true)
  with check (true);

alter publication supabase_realtime add table public.project_messages;

-- 4) Avaliação do cliente sobre a etapa atual (estrelas + comentário) —
-- só leitura pra equipe, escrita só via função (ver abaixo).
create table if not exists public.project_feedback (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  stage_label text,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

alter table public.project_feedback enable row level security;

create policy "authenticated_select_project_feedback"
  on public.project_feedback for select
  to authenticated
  using (true);

-- 5) Gatilhos que alimentam project_notifications sozinhos, a partir de
-- eventos reais. Todos "security definer" pra conseguir gravar em
-- project_notifications mesmo sem policy de insert pra authenticated (só
-- os gatilhos escrevem ali, nunca a equipe direto).

create or replace function public.fn_notify_document()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.project_id is not null and new.owner_id is null then
    insert into public.project_notifications (project_id, type, title, body)
    values (
      new.project_id,
      'document',
      'Documento disponibilizado',
      '"' || new.file_name || '" foi compartilhado com você.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_document on public.drive_files;
create trigger trg_notify_document
  after insert on public.drive_files
  for each row
  execute function public.fn_notify_document();

create or replace function public.fn_notify_invoice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.project_notifications (project_id, type, title, body)
  values (
    new.project_id,
    'invoice',
    'Fatura emitida',
    'A fatura "' || new.description || '" já está disponível.'
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_invoice on public.invoices;
create trigger trg_notify_invoice
  after insert on public.invoices
  for each row
  execute function public.fn_notify_invoice();

create or replace function public.fn_notify_task()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.project_id is not null then
    insert into public.project_notifications (project_id, type, title, body)
    values (
      new.project_id,
      'task',
      'Nova atividade adicionada',
      'A equipe adicionou "' || new.title || '" ao projeto.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_task on public.tasks;
create trigger trg_notify_task
  after insert on public.tasks
  for each row
  execute function public.fn_notify_task();

create or replace function public.fn_notify_task_done()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.project_id is not null
     and new.status = 'done'
     and old.status is distinct from 'done' then
    insert into public.project_notifications (project_id, type, title, body)
    values (
      new.project_id,
      'task_done',
      'Atividade concluída',
      '"' || new.title || '" foi concluída.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_task_done on public.tasks;
create trigger trg_notify_task_done
  after update on public.tasks
  for each row
  execute function public.fn_notify_task_done();

create or replace function public.fn_notify_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rotulo text;
begin
  if new.status is distinct from old.status then
    rotulo := case new.status
      when 'planejamento' then 'Planejamento'
      when 'execucao' then 'Execução'
      when 'revisao' then 'Revisão'
      when 'concluido' then 'Conclusão'
      else new.status
    end;
    insert into public.project_notifications (project_id, type, title, body)
    values (
      new.id,
      'status',
      'Etapa do projeto atualizada',
      'O projeto avançou para "' || rotulo || '".'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_status on public.projects;
create trigger trg_notify_status
  after update on public.projects
  for each row
  execute function public.fn_notify_status();

create or replace function public.fn_notify_team_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.sender_type = 'team' then
    insert into public.project_notifications (project_id, type, title, body)
    values (
      new.project_id,
      'message',
      'Comentário da equipe',
      coalesce(new.sender_label, 'A equipe') || ' comentou no seu projeto.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_team_message on public.project_messages;
create trigger trg_notify_team_message
  after insert on public.project_messages
  for each row
  execute function public.fn_notify_team_message();

-- 6) Funções públicas (travadas por share_token) pro link do cliente —
-- mesmo padrão de segurança de get_project_progress/get_project_documents/
-- get_project_invoices: a pessoa sem login só chama a função, nunca lê as
-- tabelas direto.

-- Resumo geral do projeto pra aba "Visão geral": dados do card "Seu
-- projeto" + o checklist (calculado, nunca marcado manualmente pelo
-- cliente — decisão do Erick: o cliente só visualiza).
create or replace function public.get_project_overview(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id, name, status, responsible_label, start_date, target_end_date,
         initial_info_confirmed, created_at
  into projeto
  from public.projects
  where share_token = p_token;

  if not found then
    return null;
  end if;

  select json_build_object(
    'project_name', projeto.name,
    'status', projeto.status,
    'responsible_label', projeto.responsible_label,
    'start_date', projeto.start_date,
    'target_end_date', projeto.target_end_date,
    'created_at', projeto.created_at,
    'checklist', json_build_array(
      json_build_object(
        'key', 'dados',
        'title', 'Confirmar dados do projeto',
        'description', 'Responsável, status e datas do projeto já definidos.',
        'done', (
          projeto.responsible_label is not null
          and projeto.start_date is not null
          and projeto.target_end_date is not null
        )
      ),
      json_build_object(
        'key', 'documentos',
        'title', 'Enviar documentos necessários',
        'description', 'Contrato, materiais e outros arquivos compartilhados.',
        'done', exists (
          select 1 from public.drive_files
          where project_id = projeto.id and owner_id is null
        )
      ),
      json_build_object(
        'key', 'equipe',
        'title', 'Conhecer a equipe responsável',
        'description', 'Veja quem está cuidando do seu projeto.',
        'done', (projeto.responsible_label is not null)
      ),
      json_build_object(
        'key', 'informacoes',
        'title', 'Responder informações iniciais',
        'description', 'Alinhamento inicial com a equipe.',
        'done', projeto.initial_info_confirmed
      ),
      json_build_object(
        'key', 'pronto',
        'title', 'Projeto pronto para acompanhamento',
        'description', 'O projeto já está em execução.',
        'done', (projeto.status in ('execucao', 'revisao', 'concluido'))
      )
    )
  )
  into resultado;

  return resultado;
end;
$$;

grant execute on function public.get_project_overview(uuid) to anon, authenticated;

-- Equipe do projeto pra card "Sua equipe": o responsável (projects.
-- responsible_id) + todo mundo que tem alguma tarefa atribuída no
-- projeto — não existe um cadastro de "time do projeto" à parte.
create or replace function public.get_project_team(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id, responsible_id into projeto
  from public.projects
  where share_token = p_token;

  if not found then
    return null;
  end if;

  select coalesce(json_agg(
    json_build_object(
      'id', p.id,
      'name', coalesce(p.name, p.username, 'Alguém da equipe'),
      'avatar_url', p.avatar_url,
      'is_responsible', (p.id = projeto.responsible_id)
    )
    order by (p.id = projeto.responsible_id) desc, coalesce(p.name, p.username)
  ), '[]'::json)
  into resultado
  from public.profiles p
  where p.id = projeto.responsible_id
     or p.id in (
       select unnest(t.assigned_to)
       from public.tasks t
       where t.project_id = projeto.id
     );

  return resultado;
end;
$$;

grant execute on function public.get_project_team(uuid) to anon, authenticated;

-- Últimas notificações/atividades do projeto.
create or replace function public.get_project_notifications(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    return null;
  end if;

  select coalesce(json_agg(
    json_build_object(
      'id', n.id,
      'type', n.type,
      'title', n.title,
      'body', n.body,
      'created_at', n.created_at
    )
    order by n.created_at desc
  ), '[]'::json)
  into resultado
  from (
    select * from public.project_notifications
    where project_id = projeto.id
    order by created_at desc
    limit 40
  ) n;

  return resultado;
end;
$$;

grant execute on function public.get_project_notifications(uuid) to anon, authenticated;

-- Mensagens da conversa (equipe + cliente).
create or replace function public.get_project_messages(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  resultado json;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    return null;
  end if;

  select coalesce(json_agg(
    json_build_object(
      'id', m.id,
      'sender_type', m.sender_type,
      'sender_label', m.sender_label,
      'content', m.content,
      'created_at', m.created_at
    )
    order by m.created_at asc
  ), '[]'::json)
  into resultado
  from (
    select * from public.project_messages
    where project_id = projeto.id
    order by created_at desc
    limit 100
  ) m;

  return resultado;
end;
$$;

grant execute on function public.get_project_messages(uuid) to anon, authenticated;

-- O cliente manda mensagem por aqui (nunca com insert direto na tabela).
-- Valida conteúdo não vazio e um limite de tamanho, só isso.
create or replace function public.send_project_message(
  p_token uuid,
  p_content text,
  p_sender_label text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
  conteudo text;
  nova record;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    return null;
  end if;

  conteudo := trim(coalesce(p_content, ''));
  if conteudo = '' or length(conteudo) > 2000 then
    return null;
  end if;

  insert into public.project_messages (project_id, sender_type, sender_label, content)
  values (
    projeto.id,
    'client',
    coalesce(nullif(trim(coalesce(p_sender_label, '')), ''), 'Cliente'),
    conteudo
  )
  returning id, sender_type, sender_label, content, created_at into nova;

  return json_build_object(
    'id', nova.id,
    'sender_type', nova.sender_type,
    'sender_label', nova.sender_label,
    'content', nova.content,
    'created_at', nova.created_at
  );
end;
$$;

grant execute on function public.send_project_message(uuid, text, text) to anon, authenticated;

-- Avaliação do cliente sobre a etapa atual.
create or replace function public.submit_project_feedback(
  p_token uuid,
  p_stage_label text,
  p_rating int,
  p_comment text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  projeto record;
begin
  select id into projeto from public.projects where share_token = p_token;
  if not found then
    return false;
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    return false;
  end if;

  insert into public.project_feedback (project_id, stage_label, rating, comment)
  values (
    projeto.id,
    nullif(trim(coalesce(p_stage_label, '')), ''),
    p_rating,
    nullif(trim(coalesce(p_comment, '')), '')
  );

  return true;
end;
$$;

grant execute on function public.submit_project_feedback(uuid, text, int, text) to anon, authenticated;


-- ===== 0032_catalog_systems.sql =====
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
