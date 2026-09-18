# Mytek Hub

Hub interno de operação para equipes: três módulos no mesmo projeto, com o
mesmo login:

- **Tarefas** (`/board`): quadro A Fazer / Em Andamento / Concluído, com
  sincronização em tempo real entre todo mundo logado ao mesmo tempo.
- **Wiki** (`/wiki`): páginas de texto rico com editor de blocos (tipo
  Notion), usando a biblioteca open-source
  [BlockNote](https://www.blocknotejs.org/) — plugada direto no nosso
  próprio banco em vez de vir com um app inteiro de terceiros junto.
- **Mensagens** (`/chat`): conversas diretas e por canal entre pessoas do
  time, em tempo real.

Além disso, o projeto inclui gestão de **Projetos**, **Calendário**,
**Solicitações** e um **portal de acompanhamento para clientes**
(`/progresso/[token]`), com faturas, documentos e linha do tempo.

**Stack:** Next.js (App Router) + Supabase (banco + autenticação) +
Tailwind + BlockNote/Mantine (editor da wiki), pronto pra abrir no Cursor e
publicar na Vercel.

## 1. Criar o projeto no Supabase

1. Crie uma conta/projeto em [supabase.com](https://supabase.com) (tem plano gratuito).
2. Em **Project Settings → API**, copie a **Project URL** e a **anon public key**.
3. Em **SQL Editor**, cole e rode, em ordem, os arquivos de
   `supabase/migrations/` — isso cria as tabelas, as permissões de acesso e
   liga o tempo real.
4. (Opcional, recomendado pra protótipo interno) Em **Authentication → Providers → Email**,
   desative "Confirm email" pra não depender de configurar envio de e-mail
   agora. Dá pra reativar depois.

## 2. Rodar localmente

```bash
cd mytek-hub
cp .env.local.example .env.local
# edite .env.local com a URL e a anon key do seu projeto Supabase

npm install
npm run dev
```

Acesse `http://localhost:3000`, crie sua conta (tela de cadastro) e comece
a usar o quadro de tarefas, a wiki e as mensagens (links no menu lateral).
Pra testar o chat de verdade, crie uma segunda conta (outro usuário) numa
aba anônima.

## 3. Publicar na Vercel

1. Suba esse projeto pra um repositório no GitHub da MyTek.
2. Em [vercel.com](https://vercel.com), importe o repositório.
3. Em **Environment Variables**, adicione as mesmas duas variáveis do
   `.env.local`:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
4. Deploy.

## Identidade visual

A UI usa a paleta da marca mytek (azul `#175dfc` no tema claro,
`#3180ff` no escuro) — ver `app/globals.css` e `tailwind.config.ts`. O
ícone da marca está em `public/brand/logo.png`.

## Estrutura do projeto

```
app/
  page.tsx                → redireciona para /login ou /board
  login/page.tsx          → tela de entrar/criar conta
  onboarding/page.tsx     → configuração inicial do workspace
  (app)/board/page.tsx    → quadro de tarefas (protegido por login)
  (app)/calendario/       → calendário da equipe
  (app)/wiki/             → wiki (lista + editor de páginas)
  (app)/chat/             → mensagens diretas e por canal
  (app)/projetos/         → gestão de projetos
  (app)/solicitacoes/     → solicitações internas
  progresso/[token]/      → portal público de acompanhamento do cliente
components/                → componentes de UI e lógica de cada módulo
lib/                       → clientes Supabase, tipos e utilitários
middleware.ts               → protege as rotas (exige login)
supabase/migrations/        → SQL do banco de dados
```
