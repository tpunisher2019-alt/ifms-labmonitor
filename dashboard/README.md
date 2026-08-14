# Painel IFMS LabMonitor

Painel privado para visualizar estações, eventos e inventário, solicitar uma nova coleta e distribuir versões cadastradas do agente.

## Configuração

Copie `.env.example` para `.env.local` e preencha a URL e a chave secreta do Supabase. A chave é utilizada apenas no servidor.

Instale as dependências e valide:

```text
pnpm install
pnpm build
```

Sem credenciais, o painel abre em modo de demonstração com dados fictícios. A criação de tarefas permanece indisponível.

Em produção, publique como site privado. As rotas de escrita exigem a identidade autenticada encaminhada pela hospedagem.

