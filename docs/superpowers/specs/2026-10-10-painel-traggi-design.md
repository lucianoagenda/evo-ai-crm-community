# Painel do Traggi na conversa do CRM

Data: 2026-10-10
Repositórios afetados: `evo-ai-crm-community` (backend Rails), `evo-ai-frontend-community` (React) e o Traggi (PHP/CodeIgniter, deploy por FTP).

## Contexto e objetivo

O agente de reengajamento e a IA de lead do Traggi encaminham conversas para o time no EVO CRM. Hoje, para devolver à IA, encerrar ou marcar opt-out, é preciso sair do CRM e abrir o painel do Traggi (*Agente › Abordagem #* ou *Agente › Lead #*).

Objetivo: trazer essa gestão para a conversa do CRM. Quem finaliza o atendimento clica ali mesmo e a ação vale no Traggi, com as mesmas regras do painel.

### Decisões do usuário

- Vale para **leads e clientes** (abordagens). O painel descobre pelo telefone do contato.
- Fica na **barra lateral da conversa** (painel do contato).
- **Nenhuma ação automática** ao resolver a conversa: só os botões.
- Entrega em **branches de feature** (`feature/painel-traggi`) nos dois repositórios do CRM. O merge na `main` (que gera a imagem de produção) é do usuário.

### Critérios de sucesso

- Ao abrir o painel do contato de uma conversa de WhatsApp, quem tem acesso à conversa vê:
  - a situação no Traggi (lead ou cliente, status, resumo, se a IA está respondendo);
  - os botões permitidos naquela situação.
- Clicar num botão muda o estado no Traggi exatamente como o botão equivalente do painel do Traggi.
- A chave do Traggi nunca chega ao navegador.
- Sem configuração (`TRAGGI_API_URL`/`TRAGGI_API_KEY` vazias), o CRM se comporta como hoje: a seção não aparece.

### Fora de escopo

- Ação automática ao resolver a conversa.
- Painel no card do pipeline.
- Encaminhar para o CRM, liberar teste, excluir da fila (ações que não fazem sentido de dentro do CRM).
- Mostrar as mensagens do Traggi (o histórico já está na conversa do CRM).

## Alternativas descartadas

- **Navegador chamando o Traggi direto**: a chave ficaria exposta no navegador.
- **Dashboard App (iframe do Traggi)**: as abas de Dashboard App estão desligadas no chat (`dashboardApps` nunca é carregado em `Chat.tsx`). Além disso, o login do Traggi dentro de um iframe de outro domínio esbarra no bloqueio de cookies de terceiros.

## Arquitetura

```
CRM frontend ──(JWT do usuário)──▶ CRM backend ──(Api-Key, servidor a servidor)──▶ Traggi /api/agente/crm/*
```

### 1. Traggi

Autenticação igual à das outras rotas do agente: header `Api-Key` = `settings.api_key` (ou o Bearer do agente).

**`GET /api/agente/crm/situacao?telefone=5548...`**

```json
{
  "tipo": "lead" | "cliente" | "nenhum",
  "id": 12,
  "status": "com_time",
  "status_rotulo": "Com o time",
  "nome": "Joana",
  "ia_respondendo": false,
  "opt_out": false,
  "resumo": "...",
  "motivo": "...",
  "atualizado_em": "2026-10-10 14:00:00",
  "acoes": ["devolver", "encerrar", "opt_out"],
  "motivos": [{"chave": "preco", "rotulo": "Preço"}],
  "link": "https://.../admin/agente/lead/12"
}
```

- **lead:** o lead mais recente do telefone, não simulado, quando o telefone não tem conta.
- **cliente:** o telefone tem conta e há abordagem (`atual_do_cliente`, a mesma escolha do `identificar`). Telefone com conta e sem abordagem dá `tipo: "nenhum"`.
- **LGPD:** nada de e-mail, CPF ou pagamento. O nome é o do WhatsApp (lead) ou o nome do responsável já usado pelo agente.
- **`acoes`** (mesmas regras das telas do painel):

  | tipo | ação | quando |
  |---|---|---|
  | lead | `devolver` | status `com_time` ou `encerrado` |
  | lead | `encerrar` | status `em_conversa` ou `com_time` |
  | lead | `opt_out` | status diferente de `opt_out` e `virou_cliente` |
  | cliente | `devolver` | status `atendimento_humano` |
  | cliente | `reabrir` | status `encerrado` ou `sem_resposta` |
  | cliente | `encerrar` | `Transicoes::permitida(status, 'encerrado')` |
  | cliente | `opt_out` | telefone/cliente fora da lista de opt-out |

- **`motivos`:** só para cliente que não é assinante, já que assinante não tem motivo de não conversão (regra do `mudar_status`).
- **`ia_respondendo`:** o número não está em opt-out e o número está liberado (modo teste: só telefones de teste). Além disso, para cada tipo:
  - **lead:** status `em_conversa` e *Atendimento de desconhecidos* ligado;
  - **cliente:** status `enviado`, `em_conversa` ou `aguardando_retorno` e *Abordagens* ligadas.

**`POST /api/agente/crm/acao`**

Corpo: `{"telefone", "tipo", "id", "acao", "observacao"?, "motivo_categoria"?, "usuario"?}`

- Confere que o registro (`tipo`/`id`) é do telefone informado. Se não for, responde 404.
- Confere que a ação está em `acoes` da situação atual. Se não estiver, responde 409 com a mensagem.
- Executa pelos mesmos métodos do painel, com origem `admin`:
  - **lead:** `devolver_lead`, `encerrar_lead` e `opt_out_lead`;
  - **cliente:** `mudar_status em_conversa` (devolver/reabrir), `encerrar` (com `motivo_categoria` opcional) e `opt_out`.
- Registra que veio do CRM:
  - **encerrar com observação:** resumo `Encerrado no CRM por <usuario>: <observação>`;
  - **opt-out:** observação `Marcado no CRM por <usuario>`.
- Responde com a situação nova (mesmo formato do GET).

A regra das ações fica numa classe pura (`App\Agente\PainelCrm`) testada no PHPUnit. O serviço (`Agente_crm_painel_service`, que estende `Agente_lead_service`) faz as consultas e as chamadas.

### 2. CRM backend

- **`Traggi::Client`** (`app/services/traggi/client.rb`):
  - HTTParty, com timeout de 5 s, `ENV['TRAGGI_API_URL']` e `ENV['TRAGGI_API_KEY']`;
  - `configured?`, `situacao(telefone)` e `acao(payload)`;
  - erros viram `Traggi::Client::Error` com status e mensagem (a mensagem `erro` que o Traggi devolve).
- **`Api::V1::Conversations::TraggiController`** (herda de `Conversations::BaseController`, que já autoriza a conversa):
  - `GET /api/v1/conversations/:conversation_id/traggi` (permissão `conversations.read`);
  - `POST /api/v1/conversations/:conversation_id/traggi/acao` (permissão `conversations.update`).
  - Sem configuração, a resposta é `{configured: false}` com 200, e o frontend esconde a seção.
  - Contato sem telefone dá `{configured: true, tipo: 'nenhum'}` sem chamar o Traggi.
  - Envia o telefone do contato da conversa. Nunca usa um telefone vindo do navegador.
  - `usuario` = `Current.user.name`.
  - Erro do Traggi vira `error_response` com a mensagem dele:
    - 4xx do Traggi → 422 `BUSINESS_RULE_VIOLATION`;
    - falha de rede ou 5xx → 502.
- As specs entram no `traggi-specs.yml`.

### 3. CRM frontend

- `services/traggi/traggiService.ts`: `getSituacao(conversationId)` e `executarAcao(conversationId, payload)`.
- `components/chat/contact-sidebar/TraggiPanel.tsx`: card na barra lateral, abaixo dos detalhes do contato.
  - Carrega a situação quando a conversa muda.
  - Fica escondido se `configured` for falso, se o tipo for `nenhum` ou se a carga der erro. Um erro na carga não pode quebrar a barra lateral.
  - Mostra:
    - o título "Traggi · IA de atendimento";
    - o selo com o tipo (Lead/Cliente) e o `status_rotulo`;
    - "IA respondendo" ou "IA em silêncio";
    - o resumo e o motivo;
    - o link "Abrir no Traggi".
  - Botões conforme `acoes`. Cada um abre um `Dialog` de confirmação (sem `confirm()` nativo):
    - Encerrar tem campo de observação e, se houver `motivos`, um seletor de motivo;
    - depois da ação, um toast de sucesso, e a situação é atualizada com a resposta;
    - em caso de erro, um toast com a mensagem do Traggi.
- Textos em `i18n/locales/{en,pt-BR}/chat.json` (`traggiPanel.*`). Os outros idiomas usam o fallback.

## Testes

- **Traggi:**
  - `tests/Agente/PainelCrmTest.php` cobre as ações por status e `ia_respondendo`;
  - `api_local.sh` ganha a seção "painel do CRM": situação de lead/cliente/nenhum, as ações, 409 para ação não permitida, 404 para id de outro telefone e ausência de e-mail.
- **CRM backend:** `spec/services/traggi/client_spec.rb` (WebMock) e `spec/requests/api/v1/conversations/traggi_spec.rb`, rodando no CI.
- **CRM frontend:** `TraggiPanel.spec.tsx` e o `i18n-parity.spec.ts` existente, no vitest local.

## Deploy

1. **Traggi** (FTP):
   - `application/libraries/Agente/PainelCrm.php` (novo)
   - `application/libraries/Agente/carregar.php`
   - `application/libraries/Agente_crm_painel_service.php` (novo)
   - `application/controllers/Api_agente.php`
   - `application/config/routes.php`

   Não há SQL.
2. **CRM:** merge de `feature/painel-traggi` na `main` nos dois repositórios, o que gera as imagens. No serviço do CRM (Rails) do `docker-compose`:
   - `TRAGGI_API_URL=https://<domínio do Traggi>`
   - `TRAGGI_API_KEY=<settings.api_key do Traggi>`
