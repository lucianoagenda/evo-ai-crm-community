# Mover card entre colunas/pipelines e trocar o WhatsApp de saída

Data: 2026-09-26
Repositórios afetados: `evo-ai-crm-community` (backend Rails) e `evo-ai-frontend-community` (React).

## Contexto e objetivo

Dois pedidos de melhoria:

1. **Mover o card pelo próprio card** para outra coluna (etapa) ou outro pipeline.
2. **Escolher o WhatsApp de saída** entre os números conectados, mantendo todo o histórico no mesmo card.

Motivação do item 2 (confirmada): **o número caiu, foi banido ou desconectou** e o atendimento precisa continuar por outro número sem perder o histórico.

### Critérios de sucesso

- Pelo menu do card, o usuário move o card para qualquer etapa de qualquer pipeline a que tenha acesso. O card continua o mesmo, com o histórico de movimentações, as tarefas e os produtos.
- O usuário troca o WhatsApp de uma conversa em poucos cliques. As próximas mensagens saem pelo número novo, as respostas do cliente no número novo caem na mesma conversa, e o card continua mostrando o histórico completo.

### Fora de escopo

- Juntar várias conversas num card só (abordagem descartada, ver "Alternativas").
- Trocar para canais que não sejam WhatsApp.
- Redirecionar mensagens que o cliente envie ao número antigo depois da troca.

---

## Item 1: "Mover para…" no card

### Backend

`PATCH /api/v1/pipelines/:pipeline_id/pipeline_items/:id/move_to_stage` (em `Api::V1::PipelineItemsController#move_to_stage`) passa a aceitar o parâmetro opcional `target_pipeline_id` junto com o `new_stage_id` que já existe.

- `target_pipeline_id` ausente ou igual ao pipeline atual: comportamento de hoje (`PipelineItem#move_to_stage`).
- `target_pipeline_id` diferente:
  - carrega o pipeline de destino e a etapa (`target_pipeline.pipeline_stages.find(new_stage_id)`);
  - `authorize target_pipeline, :update_items?`, além da checagem do pipeline de origem que já existe (sem checagem para service tokens, seguindo `authorize_source_pipeline!`);
  - recusa se o pipeline de destino estiver arquivado (mesma regra de `reject_archived_pipeline`);
  - chama `Pipelines::ConversationService#move_to_pipeline_stage(item, stage)`. Esse método já preserva o card (id, `entered_at`, `custom_fields`, movimentações, tarefas, produtos), registra a movimentação `cross_pipeline`, notifica e executa as automações da etapa de destino. Serve para cards de conversa e de lead.
- **Conflito:** se o contato ou a conversa já tiver um card ativo no pipeline de destino, verificar antes de mover e responder **422** com `existing_stage` e `existing_stage_id`, no mesmo formato de `create`.
- A observação opcional (`notes`) é gravada na última movimentação, como já acontece hoje.
- Resposta de sucesso inclui `pipeline_id`, `stage_id` e `movement_type` (`same_pipeline` ou `cross_pipeline`).

### Frontend

- `PipelineItemCard`: nova entrada **"Mover para…"** no menu "⋯", pela prop `onMove`.
- Novo componente `components/pipelines/MoveItemModal.tsx`:
  - seletor de Pipeline (padrão: o atual, lista só os não arquivados e acessíveis);
  - seletor de Etapa (recarrega quando o pipeline muda; no mesmo pipeline, a etapa atual fica desabilitada);
  - campo opcional de observação;
  - mostra a mensagem do erro 422 de conflito.
- `PipelineKanban`:
  - mesmo pipeline: move o card de coluna localmente (atualização otimista, desfeita se der erro);
  - outro pipeline: tira o card do quadro e mostra um aviso com o link "Ver no pipeline X".
- Novo método no serviço de pipelines para mandar `target_pipeline_id`.
- Textos em `i18n/locales/*/pipelines.json` (pt-BR e en obrigatórios; demais idiomas com fallback).

---

## Item 2: troca do WhatsApp de saída

### Abordagem escolhida: trocar o número da própria conversa

A conversa continua a mesma e só muda de caixa de entrada. Mensagens não são copiadas nem movidas. Cada mensagem já guarda `messages.inbox_id`, que registra por qual número ela passou. O card aponta para a conversa, então continua com o histórico completo.

### Backend

**Serviço `Conversations::SwitchInboxService`** (`app/services/conversations/switch_inbox_service.rb`)

Recebe `conversation`, `target_inbox` e `user`. Valida:

| Regra | Erro |
|---|---|
| A conversa atual é de WhatsApp (`inbox.channel` é `Channel::Whatsapp`) | 422 `not_whatsapp_conversation` |
| O destino é `Channel::Whatsapp` | 422 `target_not_whatsapp` |
| O destino é diferente do número atual | 422 `same_inbox` |
| O usuário é membro da caixa de entrada de destino (ou administrador) | 403 |
| O destino está conectado (mesma checagem de conexão que a tela de caixas de entrada usa) | 422 `target_disconnected` |
| O contato tem `phone_number` | 422 `contact_without_phone` |

Depois, numa transação:

1. `ContactInboxBuilder` encontra ou cria o `ContactInbox` do contato no novo número (o `source_id` segue o formato do provedor, igual ao dos serviços de entrada).
2. `conversation.update!(inbox_id: target.id, contact_inbox_id: contact_inbox.id)`.
3. Cria a mensagem de atividade: "Canal alterado de *Nome A* para *Nome B* por *Usuário*".

Depois do commit, dispara `conversation.updated` pelo dispatcher, para que as telas conectadas via websocket se atualizem.

**Endpoint:** `POST /api/v1/conversations/:id/switch_inbox` com o corpo `{ inbox_id }`. Novo `member` em `config/routes.rb` e nova ação no `ConversationsController`, com uma regra de permissão (policy) equivalente à de atualizar a conversa.

**Serializer de mensagem:** passa a expor `inbox_id` e `inbox_name`, se ainda não estiverem lá.

**Regra de 24h da API oficial da Meta:** `Conversations::MessageWindowService` passa a considerar só as mensagens recebidas pelo **número atual** da conversa (`messages.inbox_id = conversation.inbox_id`). Sem isso, a regra das 24h ficaria errada depois da troca.

**Mensagens que chegam depois:** os serviços de entrada do WhatsApp (`incoming_message_*`, `evolution_handlers/messages_upsert`, `conversation_sync_service`) procuram a conversa pelo `contact_inbox`. Depois da troca, uma resposta no número novo encontra o `ContactInbox` novo e cai nesta mesma conversa. Um teste de integração cobre esse comportamento.

### Frontend

- **Seletor "Enviar por"** (`ChatArea`, acima da caixa de mensagem):
  - aparece só em conversa de WhatsApp quando o usuário tem acesso a mais de um número WhatsApp;
  - o menu lista os números com a situação da conexão; desconectados aparecem desabilitados;
  - ao escolher, pede confirmação ("As próximas mensagens sairão por *Número B*. O histórico continua nesta conversa.") e chama `switch_inbox`.
- **Aviso de número desconectado:** se o número atual da conversa estiver desconectado, mostra um aviso "Este número está desconectado — trocar número" que abre o seletor.
- **Card:** nova entrada **"Trocar número de WhatsApp…"** no menu "⋯", só para cards com conversa de WhatsApp. Abre a mesma janela (componente compartilhado `SwitchInboxDialog`). A linha do card que mostra a caixa de entrada reflete o novo número.
- **`MessageBubble`:** quando `message.inbox_id` é diferente do número atual da conversa, mostra a etiqueta discreta "via *Nome do número*".
- Textos nos arquivos de tradução de chat e de pipelines.

### Comportamentos aceitos (documentados)

- Se o cliente escrever no número antigo depois da troca, abre uma conversa nova no número antigo (comportamento padrão).
- Relatórios por caixa de entrada passam a contar a conversa no número atual. As mensagens antigas continuam contando para o número por onde passaram.
- Se o número de destino usar a API oficial da Meta sem mensagem recebida nas últimas 24h, a troca é permitida, mas a caixa de mensagem exige template (comportamento que já existe).

---

## Alternativas consideradas

- **Nova conversa por número, com o card juntando várias conversas.** Exigiria uma tabela de ligação, uma linha do tempo que junta mensagens de várias conversas e mudanças nas automações que assumem "card = uma conversa". Custo alto e sem benefício para o caso "número caiu". Descartada.

## Testes

**Backend (RSpec)**
- `SwitchInboxService`: sucesso (reaproveitando `ContactInbox` e criando um novo), cada recusa da tabela e rollback se a criação da atividade falhar.
- Request spec de `switch_inbox`: permissões (membro, não membro, administrador).
- `MessageWindowService`: a regra de 24h considera só o número atual depois da troca.
- Integração: mensagem recebida via Evolution no número novo cai na mesma conversa.
- `move_to_stage` entre pipelines: sucesso com card de conversa, sucesso com card de lead, conflito 422, sem permissão no destino (403), pipeline de destino arquivado.

**Frontend (Vitest)**
- `MoveItemModal`: carrega as etapas quando o pipeline muda; mostra o erro de conflito.
- Seletor "Enviar por": oculto com um número só; desconectados desabilitados; chama o endpoint depois de confirmar.
- `MessageBubble`: etiqueta "via" só quando o número difere do atual.
- `PipelineItemCard`: novas entradas do menu aparecem conforme o tipo do card.

## Ordem de entrega sugerida

1. Item 1 (backend e depois frontend): independente e de valor imediato.
2. Item 2, backend (serviço, endpoint, ajuste da regra de 24h, serializer).
3. Item 2, frontend (seletor, aviso, ação no card, etiqueta "via").

---

## Ajustes feitos na implementação (2026-09-26)

- **Onde fica o "Mover para…":** o Kanban já tinha um menu de mover (ícone ⇄) restrito ao mesmo pipeline, e a ficha do card (`EditItemModal`) já tinha seletor de etapa. O "Outro pipeline…" foi adicionado nesses dois lugares (não em `PipelineItemCard`, que não é usado no Kanban).
- **Após mover:** o Kanban recarrega os dados (padrão existente do quadro) em vez de atualização otimista.
- **Serializer de mensagem:** expõe só `inbox_id`; o nome do número vem do store de inboxes no frontend.
- **Destino "indisponível":** `connection_state` em `disconnected`/`error`. `unknown`/`pending` são permitidos, porque provedores por token (ex.: `whatsapp_cloud`) costumam reportar `unknown`.
- **Bug corrigido de carona:** `PipelineItemsController#set_pipeline_item` buscava a conversa por `display_id` com qualquer parâmetro; o cast de integer fazia UUIDs como `00000001-…` casarem com a conversa #1 e mover o card errado. Agora só busca por `display_id` com parâmetro numérico.
