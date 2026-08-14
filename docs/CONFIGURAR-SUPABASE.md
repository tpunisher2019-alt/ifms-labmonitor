# Configuração do Supabase

## Capacidade do plano gratuito

Em agosto de 2026, a documentação do Supabase informa no plano gratuito 500 MB de banco, 1 GB de arquivos, 5 GB de saída e 500 mil chamadas mensais de Edge Functions. Esses limites podem mudar.

Com sincronização a cada cinco minutos, cada estação faz aproximadamente 8.640 chamadas por mês. Cinquenta estações usam cerca de 432 mil chamadas, antes de considerar cadastros e testes. Para mais máquinas, aumente o intervalo ou utilize um plano compatível.

Documentação oficial:

- https://supabase.com/docs/guides/platform/billing-on-supabase
- https://supabase.com/docs/guides/functions/secrets
- https://supabase.com/docs/guides/storage/security/access-control

## 1. Criar o projeto

Crie um projeto no Supabase e guarde:

- URL do projeto;
- chave publicável (`sb_publishable_...`);
- chave secreta (`sb_secret_...`), usada apenas pela Edge Function e pelo servidor do painel.

## 2. Criar banco e armazenamento

Execute, nesta ordem, `supabase/migrations/001_labmonitor_v2.sql` e `supabase/migrations/002_event_retention.sql` no SQL Editor. Elas criam tabelas, índices, RLS, o bucket privado `agent-releases` e a limpeza automática.

Antes da segunda migração, habilite **Cron** em `Integrations > Cron` no painel Supabase. A limpeza roda diariamente e mantém 90 dias por padrão.

Nenhuma tabela possui política para usuários anônimos. O acesso das estações ocorre somente pela Edge Function.

## 3. Publicar a Edge Function

Publique `supabase/functions/device-sync`. A função usa autenticação própria de dispositivo, portanto seu `config.toml` contém `verify_jwt = false`. Isso não torna os dados públicos: todas as requisições de sincronização exigem o segredo individual cadastrado.

A função recebe automaticamente `SUPABASE_URL` e a chave secreta no ambiente do Supabase. Nunca copie essa chave para `network.json`.

## 4. Matricular uma estação

Gere um token aleatório diferente para cada máquina. No SQL Editor, armazene somente o hash:

```sql
insert into public.enrollment_tokens(token_hash, label, expires_at)
values (
  encode(digest('TOKEN-ALEATORIO-DA-MAQUINA', 'sha256'), 'hex'),
  'LAB01-PC01',
  now() + interval '7 days'
);
```

Na estação, como administrador, edite:

```text
%ProgramData%\IFMS\LabMonitor\config\network.json
```

Preencha URL, chave publicável e o token em texto; defina `enabled` como `true`. No primeiro contato, o token é consumido e um segredo individual passa a ser armazenado em `data\state\device-identity.json`, acessível apenas a SYSTEM e administradores.

Depois do cadastro, remova o `enrollmentToken` do arquivo de configuração.

## 5. Configurar o painel

No ambiente privado onde o painel será publicado, configure:

```text
SUPABASE_URL=https://SEU-PROJETO.supabase.co
SUPABASE_SECRET_KEY=sb_secret_...
```

A chave secreta é lida somente nas rotas de servidor. O navegador nunca a recebe. O painel deve permanecer privado e limitar operadores autorizados.

## 6. Publicar uma atualização

Assine os scripts PowerShell com um certificado institucional e gere o pacote com `tools/New-AgentRelease.ps1`. Envie o ZIP ao bucket `agent-releases` e cadastre:

```sql
insert into public.agent_releases(version, storage_path, sha256, release_notes, active)
values ('2.0.1', 'IFMS-LabMonitor-Agent-2.0.1.zip', 'SHA256_DO_ZIP', 'Correções', true);
```

O servidor fornece à estação uma URL privada com validade de quinze minutos. A estação ainda confere SHA-256, manifesto e assinatura Authenticode antes de substituir qualquer arquivo.

## 7. Retenção

Eventos podem crescer rapidamente. A versão 2 mantém 90 dias por padrão. O período pode ser alterado no painel e a função abaixo também pode ser executada manualmente:

```sql
select public.cleanup_expired_device_events();
```

Não registre conteúdo de documentos, teclas ou capturas de tela. Restrinja o painel aos profissionais responsáveis pelo laboratório.
