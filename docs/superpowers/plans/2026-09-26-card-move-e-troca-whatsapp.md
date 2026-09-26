# Mover card entre pipelines + troca do WhatsApp de saída — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permitir mover um card para etapa de outro pipeline a partir do card, e trocar o número de WhatsApp de uma conversa mantendo todo o histórico na mesma conversa/card.

**Architecture:** Backend Rails: estende `PipelineItemsController#move_to_stage` com `target_pipeline_id` (reusa `Pipelines::ConversationService#move_to_pipeline_stage`); novo `Conversations::SwitchInboxService` + `POST /conversations/:id/switch_inbox` que re-aponta `inbox_id`/`contact_inbox_id`; `MessageWindowService` passa a olhar só o inbox atual. Frontend React: `MoveItemModal` (Kanban + ficha), `SwitchInboxDialog` compartilhado (barra "Enviar por" no chat + menu do card) e etiqueta "via" nas mensagens.

**Tech Stack:** Rails 7 / RSpec (request + service specs, sem factories — registros criados com `Model.create!`), Pundit; React + TypeScript + Vitest + Testing Library, `@evoapi/design-system`, i18n via `useLanguage`.

**Spec:** `docs/superpowers/specs/2026-09-26-card-move-e-troca-whatsapp-design.md`

## Global Constraints

- Dois repositórios git separados: backend `evo-ai-crm-community` e frontend `evo-ai-frontend-community`. Trabalhar na branch `feature/card-move-e-troca-whatsapp` em **ambos** (backend já existe; no frontend criar com `git checkout -b feature/card-move-e-troca-whatsapp`).
- Customizações deste fork são marcadas com comentário `[Traggi]` (Ruby `# [Traggi] ...`, TS `// [Traggi] ...` ou `{/* [Traggi] ... */}`) na primeira linha de cada bloco novo/alterado em arquivo pré-existente. O CI `traggi-docker.yml` roda `ruby -wc` em todo `.rb` com essa marca.
- Não há Ruby nem Docker nesta máquina: specs de backend rodam **só no GitHub Actions** (Task 0). Frontend roda local: `npx vitest run <arquivo>` dentro de `evo-ai-frontend-community`.
- Textos novos no frontend: obrigatórios em `pt-BR` e `en`; demais idiomas caem no fallback.
- Mensagem de erro de pipeline arquivado é contrato (evo-flow): `'Pipeline is archived and cannot receive conversations'`, código `PIPELINE_ARCHIVED`.
- Canal de destino "indisponível" = `Channels::ConnectionStateResolver.call(channel)[:state]` em `%w[disconnected error]` (backend) / `inbox.connection_state` em `['disconnected','error']` (frontend). `unknown`/`pending` são permitidos (provedores por token, ex. `whatsapp_cloud`, costumam reportar `unknown`).
- Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nada de `git push` sem autorização explícita do usuário.

## Review Focus

1. **Card de lead (sem conversa) movido entre pipelines** — deve mover igual ao card de conversa (coberto na Task 1, teste "moves a lead card").
2. **Contato com telefone formatado com `+`/espaços** — `ContactInboxBuilder` gera `source_id` sem `+`; a troca deve reaproveitar o `ContactInbox` existente em vez de duplicar (Task 3, teste "reuses the existing contact inbox").
3. **Conversa resolvida trocada de número e cliente responde no número novo** — serviços de entrada buscam `contact_inbox.conversations.where.not(status: :resolved)`; com conversa resolvida abre conversa nova. Aceito pelo spec; o teste da Task 3 fixa o caso "aberta → cai na mesma".
4. **Troca para o mesmo número / número desconectado vindo de UI desatualizada** — backend recusa com 422 mesmo que a UI deixe passar (Task 3 e Task 4).
5. **Usuário sem acesso ao inbox de destino** — deve receber 403, não 422 nem 500 (Task 4, teste "forbids a target inbox the user cannot see").

---

## Task 0: CI para rodar as specs novas do backend na branch

**Files:**
- Create: `evo-ai-crm-community/.github/workflows/traggi-specs.yml`

**Interfaces:**
- Produces: workflow que roda em `push` para `feature/**` e executa a lista de specs Traggi.

- [ ] **Step 1: Criar o workflow**

```yaml
# [Traggi] Roda as specs das features Traggi em branches de feature.
# Não há Ruby local na máquina de desenvolvimento, então o TDD do backend usa este job.
name: Traggi - specs

on:
  push:
    branches: ['feature/**']
  workflow_dispatch:

permissions:
  contents: read

env:
  RAILS_ENV: test
  ENCRYPTION_KEY: test-encryption-key-for-fernet!!
  POSTGRES_HOST: localhost
  POSTGRES_PORT: 5432
  POSTGRES_USERNAME: postgres
  POSTGRES_PASSWORD: postgres
  POSTGRES_DATABASE: evolution_test

jobs:
  specs:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: evolution_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
      redis:
        image: redis:7
        ports:
          - 6379:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4.4'
          bundler-cache: true
      - name: Prepare test database
        run: bundle exec rails db:schema:load
      - name: Run Traggi specs
        run: |
          bundle exec rspec \
            spec/requests/api/v1/pipeline_items_cross_pipeline_move_spec.rb \
            spec/services/conversations/message_window_service_current_inbox_spec.rb \
            spec/services/conversations/switch_inbox_service_spec.rb \
            spec/requests/api/v1/conversations/switch_inbox_spec.rb \
            spec/requests/api/v1/pipeline_items_archived_spec.rb \
            --format documentation
```

- [ ] **Step 2: Commit**

```bash
git -C evo-ai-crm-community add .github/workflows/traggi-specs.yml
git -C evo-ai-crm-community commit -m "ci: roda specs Traggi em branches feature/**

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

> **Como verificar specs do backend nas tasks seguintes:** após o commit de cada task de backend, `git push -u origin feature/card-move-e-troca-whatsapp` (**somente se o usuário autorizou push**) e acompanhar com `gh run watch --repo lucianoagenda/evo-ai-crm-community`. Se push não estiver autorizado, marcar o passo "rodar specs" como pendente e seguir; todas as specs rodam juntas quando o push for liberado. Enquanto o arquivo de spec citado no workflow ainda não existir, o rspec falha com "cannot load such file" — isso é o "vermelho" esperado da primeira task que o cria.

---

## Task 1: Backend — mover card para etapa de outro pipeline

**Files:**
- Modify: `evo-ai-crm-community/app/controllers/api/v1/pipeline_items_controller.rb` (método `move_to_stage` ~linha 354; novos privados perto de `persist_notes` ~linha 588)
- Test: `evo-ai-crm-community/spec/requests/api/v1/pipeline_items_cross_pipeline_move_spec.rb`

**Interfaces:**
- Consumes: `Pipelines::ConversationService#move_to_pipeline_stage(pipeline_item, target_stage) -> Boolean` (existente).
- Produces: `PATCH /api/v1/pipelines/:pipeline_id/pipeline_items/:id/move_to_stage` com body `{ new_stage_id, target_pipeline_id?, notes? }`. Sucesso cross-pipeline → `200 { data: { pipeline_item: {...push_event_data}, movement_type: 'cross_pipeline', pipeline_id, stage_id } }`. Erros: `404 RESOURCE_NOT_FOUND` (pipeline/etapa destino), `403` (sem `update_items?` no destino), `422 PIPELINE_ARCHIVED`, `422 BUSINESS_RULE_VIOLATION` com `details.existing_stage`/`existing_stage_id` (já tem card ativo no destino).

- [ ] **Step 1: Escrever a spec (falhando)**

```ruby
# frozen_string_literal: true

require 'rails_helper'

# [Traggi] "Mover para…" no card: move_to_stage aceita target_pipeline_id.
RSpec.describe 'PATCH move_to_stage across pipelines', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:source) { Pipeline.create!(name: "Src #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:source_stage) { source.pipeline_stages.create!(name: 'Novo', position: 1) }
  let(:target) { Pipeline.create!(name: "Dst #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:target_stage) { target.pipeline_stages.create!(name: 'Qualificado', position: 1) }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let!(:item) { PipelineItem.create!(pipeline: source, pipeline_stage: source_stage, conversation: conversation) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(true)
  end

  after { Current.reset }

  def move!(params)
    patch "/api/v1/pipelines/#{source.id}/pipeline_items/#{item.id}/move_to_stage", params: params, as: :json
  end

  it 'moves the same card to a stage of another pipeline, keeping its id' do
    move!(new_stage_id: target_stage.id, target_pipeline_id: target.id, notes: 'repasse')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['data']['movement_type']).to eq('cross_pipeline')
    item.reload
    expect(item.pipeline_id).to eq(target.id)
    expect(item.pipeline_stage_id).to eq(target_stage.id)
    expect(item.stage_movements.order(:created_at).last.notes).to eq('repasse')
  end

  it 'moves a lead card (contact only) across pipelines' do
    lead_contact = Contact.create!(name: 'Só lead', email: "l-#{SecureRandom.hex(4)}@example.com")
    lead = PipelineItem.create!(pipeline: source, pipeline_stage: source_stage, contact: lead_contact)

    patch "/api/v1/pipelines/#{source.id}/pipeline_items/#{lead.id}/move_to_stage",
          params: { new_stage_id: target_stage.id, target_pipeline_id: target.id }, as: :json

    expect(response).to have_http_status(:ok)
    expect(lead.reload.pipeline_id).to eq(target.id)
  end

  it 'refuses when the item already has an active card in the target pipeline' do
    lead = PipelineItem.create!(pipeline: source, pipeline_stage: source_stage, contact: contact)
    PipelineItem.create!(pipeline: target, pipeline_stage: target_stage, contact: contact)

    patch "/api/v1/pipelines/#{source.id}/pipeline_items/#{lead.id}/move_to_stage",
          params: { new_stage_id: target_stage.id, target_pipeline_id: target.id }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']['code']).to eq('BUSINESS_RULE_VIOLATION')
    expect(response.parsed_body['error']['details']['existing_stage_id']).to eq(target_stage.id)
    expect(lead.reload.pipeline_id).to eq(source.id)
  end

  # Bug pré-existente: set_pipeline_item tentava Conversation.find_by(display_id: params[:id])
  # e o cast de integer transforma "00000001-..." em 1 — movendo o card de OUTRA conversa.
  it 'moves the card whose id was given even if the uuid starts with a conversation display_id' do
    tricky_id = format('%08d-0000-4000-8000-000000000000', conversation.display_id)
    lead_contact = Contact.create!(name: 'Lead UUID', email: "u-#{SecureRandom.hex(4)}@example.com")
    lead = PipelineItem.create!(id: tricky_id, pipeline: source, pipeline_stage: source_stage, contact: lead_contact)

    patch "/api/v1/pipelines/#{source.id}/pipeline_items/#{lead.id}/move_to_stage",
          params: { new_stage_id: target_stage.id, target_pipeline_id: target.id }, as: :json

    expect(response).to have_http_status(:ok)
    expect(lead.reload.pipeline_id).to eq(target.id)
    expect(item.reload.pipeline_id).to eq(source.id)
  end

  it 'refuses an archived target pipeline' do
    target.update!(is_active: false)

    move!(new_stage_id: target_stage.id, target_pipeline_id: target.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']['code']).to eq('PIPELINE_ARCHIVED')
    expect(response.parsed_body['error']['message']).to eq('Pipeline is archived and cannot receive conversations')
  end

  it 'returns 404 for a stage that is not in the target pipeline' do
    move!(new_stage_id: source_stage.id, target_pipeline_id: target.id)

    expect(response).to have_http_status(:not_found)
    expect(item.reload.pipeline_id).to eq(source.id)
  end

  it 'forbids a target pipeline the user cannot write to' do
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?) do |policy|
      policy.record.id != target.id
    end

    move!(new_stage_id: target_stage.id, target_pipeline_id: target.id)

    expect(response).to have_http_status(:forbidden)
    expect(item.reload.pipeline_id).to eq(source.id)
  end

  it 'keeps the same-pipeline behaviour when target_pipeline_id is the current pipeline' do
    other_stage = source.pipeline_stages.create!(name: 'Proposta', position: 2)

    move!(new_stage_id: other_stage.id, target_pipeline_id: source.id)

    expect(response).to have_http_status(:ok)
    expect(item.reload.pipeline_stage_id).to eq(other_stage.id)
  end
end
```

> Nota para o teste de conflito: o índice único impede duas linhas ativas com o mesmo `contact_id` no mesmo pipeline, então o cenário é montado transformando `item` num card de lead do `contact` e criando outro card de lead do mesmo `contact` no destino. Se `policy.record` não existir no `PipelinePolicy`, trocar por `policy.instance_variable_get(:@record)`.

- [ ] **Step 2: Rodar e ver falhar** — Task 0: push + `gh run watch`. Esperado: exemplos cross-pipeline falham (item continua no pipeline de origem / 404 "Stage not found in this pipeline").

- [ ] **Step 3: Implementar no controller**

No início de `move_to_stage`, antes do `begin`:

```ruby
  def move_to_stage
    # [Traggi] "Mover para…" no card: etapa de outro pipeline.
    return move_to_other_pipeline if cross_pipeline_move?

    begin
```

Na seção `private` (logo antes de `def persist_notes`):

```ruby
  # [Traggi] move_to_stage com target_pipeline_id diferente do pipeline da URL.
  def cross_pipeline_move?
    params[:target_pipeline_id].present? && params[:target_pipeline_id].to_s != @pipeline.id.to_s
  end

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  def move_to_other_pipeline
    target_pipeline = Pipeline.find_by(id: params[:target_pipeline_id])
    if target_pipeline.nil?
      return error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Target pipeline not found', status: :not_found)
    end

    authorize target_pipeline, :update_items? unless service_authenticated?

    unless target_pipeline.is_active
      return error_response(
        ApiErrorCodes::PIPELINE_ARCHIVED,
        'Pipeline is archived and cannot receive conversations',
        status: :unprocessable_entity
      )
    end

    target_stage = target_pipeline.pipeline_stages.find_by(id: params[:new_stage_id])
    if target_stage.nil?
      return error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Stage not found in target pipeline', status: :not_found)
    end

    existing = active_item_in(target_pipeline)
    if existing
      return error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        "Item already has an active journey in this pipeline in stage '#{existing.pipeline_stage.name}'",
        details: { existing_stage: existing.pipeline_stage.name, existing_stage_id: existing.pipeline_stage_id },
        status: :unprocessable_entity
      )
    end

    moved = Pipelines::ConversationService.new(pipeline: target_pipeline, user: Current.user)
                                          .move_to_pipeline_stage(@pipeline_item, target_stage)
    unless moved
      return error_response(ApiErrorCodes::OPERATION_FAILED, 'Failed to move item', status: :unprocessable_entity)
    end

    persist_notes(params[:notes]) if params[:notes].present?
    dispatch_conversation_updated_event(@pipeline_item.conversation)

    success_response(
      data: {
        pipeline_item: @pipeline_item.reload.push_event_data,
        movement_type: 'cross_pipeline',
        pipeline_id: target_pipeline.id,
        stage_id: target_stage.id
      },
      message: 'Item moved successfully'
    )
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

  def active_item_in(target_pipeline)
    scope = target_pipeline.pipeline_items.active
    if @pipeline_item.conversation_id.present?
      scope.find_by(conversation_id: @pipeline_item.conversation_id)
    else
      scope.find_by(contact_id: @pipeline_item.contact_id)
    end
  end
```

Confirme que `error_response` aceita `details:` (já usado em `create`) — se `create` não passa `status:`, mantenha o `status: :unprocessable_entity` aqui mesmo assim.

Corrigir também o lookup por `display_id` em `set_pipeline_item` (~linha 636) — só tentar quando o parâmetro for numérico:

```ruby
      # [Traggi] Só busca por display_id quando o parâmetro é numérico: o cast de integer
      # transformava UUIDs como "00000001-..." em 1 e movia o card de outra conversa.
      conversation = Conversation.find_by(display_id: params[:id]) if params[:id].to_s.match?(/\A\d+\z/)
      @pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation) if conversation
```

- [ ] **Step 4: Rodar e ver passar** — push + `gh run watch`. Esperado: 8 exemplos verdes; `pipeline_items_archived_spec.rb` continua verde.

- [ ] **Step 5: Commit**

```bash
git -C evo-ai-crm-community add app/controllers/api/v1/pipeline_items_controller.rb spec/requests/api/v1/pipeline_items_cross_pipeline_move_spec.rb
git -C evo-ai-crm-community commit -m "feat(pipelines): move_to_stage aceita target_pipeline_id para mover card entre pipelines

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 2: Backend — janela de 24h considera só o número atual

**Files:**
- Modify: `evo-ai-crm-community/app/services/conversations/message_window_service.rb` (método `last_incoming_message`, fim do arquivo)
- Test: `evo-ai-crm-community/spec/services/conversations/message_window_service_current_inbox_spec.rb`

**Interfaces:**
- Produces: `Conversations::MessageWindowService#can_reply?` passa a usar a última mensagem `incoming` com `inbox_id == conversation.inbox_id`.

- [ ] **Step 1: Escrever a spec (falhando)**

```ruby
# frozen_string_literal: true

require 'rails_helper'

# [Traggi] Após trocar o WhatsApp da conversa, a janela de 24h da Cloud API é
# por número: mensagens recebidas no número antigo não abrem janela no novo.
RSpec.describe Conversations::MessageWindowService do
  def wa_inbox(name, phone)
    channel = Channel::Whatsapp.new(phone_number: phone, provider: 'whatsapp_cloud',
                                    provider_config: { 'api_key' => 'x', 'phone_number_id' => '1', 'business_account_id' => '1' })
    channel.save(validate: false)
    Inbox.create!(name: name, channel: channel)
  end

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
  end

  let(:old_inbox) { wa_inbox('Antigo', "+55119#{rand(10_000_000..99_999_999)}") }
  let(:new_inbox) { wa_inbox('Novo', "+55119#{rand(10_000_000..99_999_999)}") }
  let(:contact) { Contact.create!(name: 'Cliente', phone_number: "+55219#{rand(10_000_000..99_999_999)}") }
  let(:old_ci) { ContactInbox.create!(inbox: old_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:new_ci) { ContactInbox.create!(inbox: new_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:conversation) { Conversation.create!(inbox: old_inbox, contact: contact, contact_inbox: old_ci) }

  it 'ignores incoming messages received on a previous inbox' do
    conversation.messages.create!(inbox: old_inbox, message_type: :incoming, content: 'oi', sender: contact)
    conversation.update!(inbox: new_inbox, contact_inbox: new_ci)

    allow(Rails.env).to receive(:development?).and_return(false)
    expect(described_class.new(conversation.reload).can_reply?).to be(false)
  end

  it 'opens the window with an incoming message on the current inbox' do
    conversation.update!(inbox: new_inbox, contact_inbox: new_ci)
    conversation.messages.create!(inbox: new_inbox, message_type: :incoming, content: 'oi', sender: contact)

    allow(Rails.env).to receive(:development?).and_return(false)
    expect(described_class.new(conversation.reload).can_reply?).to be(true)
  end
end
```

- [ ] **Step 2: Rodar e ver falhar** — push + `gh run watch`. Esperado: o primeiro exemplo falha (`can_reply?` retorna `true`).

- [ ] **Step 3: Implementar**

Substituir o método `last_incoming_message`:

```ruby
  # [Traggi] Só mensagens recebidas pelo número atual: a janela da Meta é por
  # número, e a conversa pode ter trocado de WhatsApp (SwitchInboxService).
  def last_incoming_message
    @last_incoming_message ||= @conversation.messages&.incoming&.where(inbox_id: @conversation.inbox_id)&.last
  end
```

- [ ] **Step 4: Rodar e ver passar** — push + `gh run watch`. Esperado: 2 exemplos verdes.

- [ ] **Step 5: Commit**

```bash
git -C evo-ai-crm-community add app/services/conversations/message_window_service.rb spec/services/conversations/message_window_service_current_inbox_spec.rb
git -C evo-ai-crm-community commit -m "fix(whatsapp): janela de 24h considera só mensagens do número atual da conversa

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 3: Backend — `Conversations::SwitchInboxService`

**Files:**
- Create: `evo-ai-crm-community/app/services/conversations/switch_inbox_service.rb`
- Test: `evo-ai-crm-community/spec/services/conversations/switch_inbox_service_spec.rb`

**Interfaces:**
- Consumes: `ContactInboxBuilder.new(contact:, inbox:, source_id: nil).perform -> ContactInbox`; `Channels::ConnectionStateResolver.call(channel) -> { state: }`; `Conversation#dispatch_conversation_updated_event` (público).
- Produces: `Conversations::SwitchInboxService.new(conversation:, target_inbox:, user:).perform -> Conversation` (recarregada). Levanta `Conversations::SwitchInboxService::Error` com `#reason` ∈ `:not_whatsapp_conversation, :target_not_whatsapp, :same_inbox, :target_disconnected, :contact_without_phone`.

- [ ] **Step 1: Escrever a spec (falhando)**

```ruby
# frozen_string_literal: true

require 'rails_helper'

# [Traggi] Troca do WhatsApp de saída mantendo a conversa (e o card) intactos.
RSpec.describe Conversations::SwitchInboxService do
  def wa_inbox(name, connection: 'open', provider: 'evolution')
    channel = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: provider,
                                    provider_config: { 'api_url' => 'http://evo.test', 'admin_token' => 'x' },
                                    provider_connection: { 'connection' => connection })
    channel.save(validate: false)
    Inbox.create!(name: name, channel: channel)
  end

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
  end

  let(:user) { User.create!(name: 'Ana', email: "ana-#{SecureRandom.hex(4)}@example.com") }
  let(:old_inbox) { wa_inbox('Número A') }
  let(:new_inbox) { wa_inbox('Número B') }
  let(:contact) { Contact.create!(name: 'Cliente', phone_number: "+55219#{rand(10_000_000..99_999_999)}") }
  let(:old_ci) { ContactInbox.create!(inbox: old_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:conversation) { Conversation.create!(inbox: old_inbox, contact: contact, contact_inbox: old_ci) }

  def perform(target = new_inbox)
    described_class.new(conversation: conversation, target_inbox: target, user: user).perform
  end

  it 're-points the conversation to the new inbox and keeps previous messages' do
    msg = conversation.messages.create!(inbox: old_inbox, message_type: :incoming, content: 'oi', sender: contact)

    result = perform

    expect(result.inbox_id).to eq(new_inbox.id)
    expect(result.contact_inbox.inbox_id).to eq(new_inbox.id)
    expect(msg.reload.inbox_id).to eq(old_inbox.id)
    expect(result.messages.where(message_type: :activity).last.content)
      .to eq('Canal alterado de Número A para Número B por Ana')
  end

  it 'reuses the existing contact inbox on the target number' do
    existing = ContactInbox.create!(inbox: new_inbox, contact: contact, source_id: contact.phone_number.delete('+'))

    expect { perform }.not_to change(ContactInbox, :count)
    expect(conversation.reload.contact_inbox_id).to eq(existing.id)
  end

  it 'makes a reply on the new number land in the same open conversation' do
    perform
    new_ci = ContactInbox.find_by!(inbox: new_inbox, contact: contact)

    # Mesma busca de Whatsapp::IncomingMessageBaseService#set_conversation.
    expect(new_ci.conversations.where.not(status: :resolved).last).to eq(conversation)
  end

  it 'dispatches conversation.updated after switching' do
    expect(conversation).to receive(:dispatch_conversation_updated_event)
    perform
  end

  it 'refuses the current inbox' do
    expect { perform(old_inbox) }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:same_inbox) }
  end

  it 'refuses a disconnected target' do
    down = wa_inbox('Caído', connection: 'close')
    expect { perform(down) }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:target_disconnected) }
  end

  it 'refuses a non-WhatsApp target' do
    web = Inbox.create!(name: 'Site', channel: Channel::WebWidget.create!(website_url: 'https://x.example.com'))
    expect { perform(web) }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:target_not_whatsapp) }
  end

  it 'refuses a non-WhatsApp conversation' do
    web = Inbox.create!(name: 'Site', channel: Channel::WebWidget.create!(website_url: 'https://y.example.com'))
    web_ci = ContactInbox.create!(inbox: web, contact: contact, source_id: SecureRandom.hex(4))
    web_conv = Conversation.create!(inbox: web, contact: contact, contact_inbox: web_ci)

    expect do
      described_class.new(conversation: web_conv, target_inbox: new_inbox, user: user).perform
    end.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:not_whatsapp_conversation) }
  end

  it 'refuses a contact without phone number' do
    contact.update_columns(phone_number: nil) # rubocop:disable Rails/SkipsModelValidations
    expect { perform }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:contact_without_phone) }
    expect(conversation.reload.inbox_id).to eq(old_inbox.id)
  end

  it 'rolls back the switch when the activity message cannot be created' do
    conversation # cria antes do stub
    # A única mensagem criada no fluxo é a de atividade.
    allow_any_instance_of(Message).to receive(:valid?).and_return(false)

    expect { perform }.to raise_error(ActiveRecord::RecordInvalid)
    expect(conversation.reload.inbox_id).to eq(old_inbox.id)
  end
end
```

- [ ] **Step 2: Rodar e ver falhar** — push + `gh run watch`. Esperado: `NameError: uninitialized constant Conversations::SwitchInboxService`.

- [ ] **Step 3: Implementar o serviço**

```ruby
# frozen_string_literal: true

# [Traggi] Troca o número de WhatsApp de uma conversa (ex.: número caiu/banido).
# A conversa continua a mesma — mensagens antigas mantêm o inbox_id por onde
# passaram — e o card do pipeline continua apontando para ela.
class Conversations::SwitchInboxService
  UNAVAILABLE_STATES = %w[disconnected error].freeze

  class Error < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  def initialize(conversation:, target_inbox:, user:)
    @conversation = conversation
    @target_inbox = target_inbox
    @user = user
  end

  def perform
    validate!
    from_inbox = @conversation.inbox

    ActiveRecord::Base.transaction do
      contact_inbox = ContactInboxBuilder.new(contact: @conversation.contact, inbox: @target_inbox, source_id: nil).perform
      @conversation.update!(inbox: @target_inbox, contact_inbox: contact_inbox)
      @conversation.messages.create!(
        inbox_id: @target_inbox.id,
        message_type: :activity,
        content: activity_content(from_inbox)
      )
    end

    @conversation.dispatch_conversation_updated_event
    @conversation.reload
  end

  private

  def validate!
    raise Error, :not_whatsapp_conversation unless whatsapp?(@conversation.inbox)
    raise Error, :target_not_whatsapp unless whatsapp?(@target_inbox)
    raise Error, :same_inbox if @target_inbox.id == @conversation.inbox_id
    raise Error, :target_disconnected if unavailable?(@target_inbox)
    raise Error, :contact_without_phone if @conversation.contact&.phone_number.blank?
  end

  def whatsapp?(inbox)
    inbox&.channel_type == 'Channel::Whatsapp'
  end

  def unavailable?(inbox)
    Channels::ConnectionStateResolver.call(inbox.channel)[:state].in?(UNAVAILABLE_STATES)
  end

  def activity_content(from_inbox)
    I18n.t(
      'conversations.activity.inbox_switched',
      from: from_inbox.name,
      to: @target_inbox.name,
      user_name: @user&.name,
      default: 'Canal alterado de %{from} para %{to} por %{user_name}' # rubocop:disable Style/FormatStringToken
    )
  end
end
```

> O I18n interpola `%{...}` (não `%<...>s`). O teste exige o texto exato `Canal alterado de Número A para Número B por Ana`.

- [ ] **Step 4: Rodar e ver passar** — push + `gh run watch`. Esperado: 10 exemplos verdes.

- [ ] **Step 5: Commit**

```bash
git -C evo-ai-crm-community add app/services/conversations/switch_inbox_service.rb spec/services/conversations/switch_inbox_service_spec.rb
git -C evo-ai-crm-community commit -m "feat(whatsapp): SwitchInboxService troca o número da conversa mantendo o histórico

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 4: Backend — endpoint `POST /conversations/:id/switch_inbox` + `inbox_id` nas mensagens

**Files:**
- Modify: `evo-ai-crm-community/config/routes.rb` (bloco `member do` de `resources :conversations`, perto de `post :unarchive` ~linha 151)
- Modify: `evo-ai-crm-community/app/controllers/api/v1/conversations_controller.rb` (`require_permissions` linha 8; nova action depois de `unarchive` ~linha 468)
- Modify: `evo-ai-crm-community/app/serializers/message_serializer.rb` (lista `only:` ~linha 24)
- Test: `evo-ai-crm-community/spec/requests/api/v1/conversations/switch_inbox_spec.rb`

**Interfaces:**
- Consumes: `Conversations::SwitchInboxService` (Task 3).
- Produces: `POST /api/v1/conversations/:id/switch_inbox` body `{ inbox_id }` → `200 { data: <ConversationSerializer> }`; `404` inbox inexistente; `403` sem acesso ao inbox de destino; `422 BUSINESS_RULE_VIOLATION` com `details.reason` (string do `Error#reason`). Mensagens serializadas passam a ter `inbox_id`.

- [ ] **Step 1: Escrever a spec (falhando)**

```ruby
# frozen_string_literal: true

require 'rails_helper'

# [Traggi] Endpoint da troca de WhatsApp da conversa.
RSpec.describe 'POST /api/v1/conversations/:id/switch_inbox', type: :request do
  def wa_inbox(name, connection: 'open')
    channel = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: 'evolution',
                                    provider_config: { 'api_url' => 'http://evo.test', 'admin_token' => 'x' },
                                    provider_connection: { 'connection' => connection })
    channel.save(validate: false)
    Inbox.create!(name: name, channel: channel)
  end

  let(:user) { User.create!(name: 'Ana', email: "ana-#{SecureRandom.hex(4)}@example.com") }
  let(:old_inbox) { wa_inbox('Número A') }
  let(:new_inbox) { wa_inbox('Número B') }
  let(:contact) { Contact.create!(name: 'Cliente', phone_number: "+55219#{rand(10_000_000..99_999_999)}") }
  let(:old_ci) { ContactInbox.create!(inbox: old_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:conversation) { Conversation.create!(inbox: old_inbox, contact: contact, contact_inbox: old_ci) }

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::V1::ConversationsController).to receive(:check_permissions!).and_return(true)
    allow_any_instance_of(InboxPolicy).to receive(:show?).and_return(true)
  end

  after { Current.reset }

  it 'switches the conversation inbox' do
    post "/api/v1/conversations/#{conversation.id}/switch_inbox", params: { inbox_id: new_inbox.id }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['data']['inbox_id']).to eq(new_inbox.id)
    expect(conversation.reload.inbox_id).to eq(new_inbox.id)
  end

  it 'returns 422 with the refusal reason' do
    post "/api/v1/conversations/#{conversation.id}/switch_inbox", params: { inbox_id: old_inbox.id }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']['code']).to eq('BUSINESS_RULE_VIOLATION')
    expect(response.parsed_body['error']['details']['reason']).to eq('same_inbox')
  end

  it 'forbids a target inbox the user cannot see' do
    allow_any_instance_of(InboxPolicy).to receive(:show?) { |policy| policy.record.id != new_inbox.id }

    post "/api/v1/conversations/#{conversation.id}/switch_inbox", params: { inbox_id: new_inbox.id }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(conversation.reload.inbox_id).to eq(old_inbox.id)
  end

  it 'returns 404 for an unknown inbox' do
    post "/api/v1/conversations/#{conversation.id}/switch_inbox", params: { inbox_id: SecureRandom.uuid }, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'exposes inbox_id on serialized messages' do
    msg = conversation.messages.create!(inbox: old_inbox, message_type: :incoming, content: 'oi', sender: contact)

    expect(MessageSerializer.serialize(msg)['inbox_id']).to eq(old_inbox.id)
  end
end
```

> Antes de rodar: abrir `app/controllers/concerns/evo_permission_concern.rb` (ou onde `require_permissions` é definido) e confirmar o nome do método de checagem que o `before_action` chama; ajustar o stub `check_permissions!` para esse nome. Idem `policy.record` no `InboxPolicy` (fallback `policy.instance_variable_get(:@record)`).

- [ ] **Step 2: Rodar e ver falhar** — push + `gh run watch`. Esperado: `ActionController::RoutingError` / 404 nas chamadas e `inbox_id` nil no serializer.

- [ ] **Step 3: Rota**

Dentro do `member do` de `resources :conversations`, depois de `post :unarchive`:

```ruby
          # [Traggi] troca o WhatsApp de saída da conversa
          post :switch_inbox
```

- [ ] **Step 4: Controller**

No hash de `require_permissions`, depois de `unarchive: 'conversations.update',`:

```ruby
    switch_inbox: 'conversations.update', # [Traggi]
```

Depois do método `unarchive` (ainda na parte pública):

```ruby
  # [Traggi] Troca o WhatsApp de saída mantendo a conversa/card (número caiu ou foi banido).
  def switch_inbox
    target_inbox = Inbox.find(params[:inbox_id])
    authorize target_inbox, :show?

    conversation = Conversations::SwitchInboxService.new(
      conversation: @conversation, target_inbox: target_inbox, user: Current.user
    ).perform

    success_response(
      data: ConversationSerializer.serialize(
        conversation,
        include_messages: false,
        include_labels: true,
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      message: 'Conversation inbox switched successfully'
    )
  rescue Conversations::SwitchInboxService::Error => e
    error_response(
      ApiErrorCodes::BUSINESS_RULE_VIOLATION,
      'Conversation inbox cannot be switched',
      details: { reason: e.reason.to_s },
      status: :unprocessable_entity
    )
  end
```

(`ActiveRecord::RecordNotFound` e `Pundit::NotAuthorizedError` já são tratados pelo `Api::V1::BaseController` → 404/403; confirmar com `grep -n "rescue_from" app/controllers/api/v1/base_controller.rb app/controllers/api/base_controller.rb`.)

- [ ] **Step 5: Serializer** — em `MessageSerializer.serialize`, adicionar `:inbox_id` à lista `only:`:

```ruby
    # [Traggi] inbox_id: a conversa pode trocar de WhatsApp; a UI mostra "via <número>".
    result = message.as_json(
      only: [:id, :content, :content_type, :content_attributes, :message_type,
             :private, :status, :source_id, :sender_type, :sender_id,
             :conversation_id, :inbox_id, :external_source_ids,
             :additional_attributes, :processed_message_content, :sentiment, :sentiment_score]
    )
```

- [ ] **Step 6: Rodar e ver passar** — push + `gh run watch`. Esperado: 5 exemplos verdes + todas as specs anteriores do workflow.

- [ ] **Step 7: Commit**

```bash
git -C evo-ai-crm-community add config/routes.rb app/controllers/api/v1/conversations_controller.rb app/serializers/message_serializer.rb spec/requests/api/v1/conversations/switch_inbox_spec.rb
git -C evo-ai-crm-community commit -m "feat(whatsapp): endpoint switch_inbox e inbox_id nas mensagens serializadas

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 5: Frontend — `MoveItemModal` + serviço

Todos os caminhos abaixo são relativos a `evo-ai-frontend-community/`. Antes da primeira task de frontend: `git -C evo-ai-frontend-community checkout -b feature/card-move-e-troca-whatsapp`.

**Files:**
- Modify: `src/types/analytics/pipelines.ts` (após `MovePipelineItemData`, ~linha 358)
- Modify: `src/services/pipelines/pipelinesService.ts` (após `moveItem`, ~linha 178)
- Create: `src/components/pipelines/MoveItemModal.tsx`
- Modify: `src/i18n/locales/pt-BR/pipelines.json`, `src/i18n/locales/en/pipelines.json` (novo bloco `moveItem` na raiz)
- Test: `src/components/pipelines/MoveItemModal.spec.tsx`

**Interfaces:**
- Consumes: `PATCH .../move_to_stage` com `target_pipeline_id` (Task 1); `pipelinesService.getPipelines({ is_active: true }) -> { data: Pipeline[] }` (cada `Pipeline` traz `stages`).
- Produces:
  - `interface MoveItemToPipelineData { item_id: string; pipeline_id: string; target_pipeline_id: string; to_stage_id: string; notes?: string }`
  - `pipelinesService.moveItemToPipeline(data): Promise<unknown>`
  - `interface MoveItemTarget { pipelineId: string; pipelineName: string; samePipeline: boolean }` (exportado de `MoveItemModal.tsx`)
  - `<MoveItemModal open onOpenChange item={PipelineItem | null} currentPipelineId={string} onMoved={(target: MoveItemTarget) => void} />`

- [ ] **Step 1: Tipo e serviço**

Em `src/types/analytics/pipelines.ts`, logo após `MovePipelineItemData`:

```ts
// [Traggi] "Mover para…" entre pipelines
export interface MoveItemToPipelineData {
  item_id: string;
  pipeline_id: string; // pipeline atual do card (URL)
  target_pipeline_id: string;
  to_stage_id: string;
  notes?: string;
}
```

Em `pipelinesService.ts`, importar `MoveItemToPipelineData` no bloco de tipos e adicionar após `moveItem`:

```ts
  // [Traggi] Move item to a stage of any pipeline (same or another)
  async moveItemToPipeline(data: MoveItemToPipelineData): Promise<unknown> {
    const response = await api.patch(
      `/pipelines/${data.pipeline_id}/pipeline_items/${data.item_id}/move_to_stage`,
      {
        new_stage_id: data.to_stage_id,
        target_pipeline_id: data.target_pipeline_id,
        notes: data.notes ?? '',
      },
    );
    return extractData<unknown>(response);
  }
```

- [ ] **Step 2: Escrever a spec (falhando)**

```tsx
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import MoveItemModal from './MoveItemModal';
import { pipelinesService } from '@/services/pipelines';

vi.mock('@/hooks/useLanguage', () => ({
  useLanguage: () => ({ t: (key: string) => key, currentLanguage: 'pt-BR' }),
}));
vi.mock('@/services/pipelines', () => ({
  pipelinesService: { getPipelines: vi.fn(), moveItemToPipeline: vi.fn() },
}));

const pipelines = [
  { id: 'p1', name: 'Vendas', is_active: true, stages: [
    { id: 's1', name: 'Novo', color: '#111' }, { id: 's2', name: 'Proposta', color: '#222' },
  ] },
  { id: 'p2', name: 'Pós-venda', is_active: true, stages: [{ id: 's3', name: 'Onboarding', color: '#333' }] },
];
const item = { id: 'i1', stage_id: 's1', pipeline_id: 'p1' } as any;

describe('MoveItemModal', () => {
  beforeEach(() => {
    vi.mocked(pipelinesService.getPipelines).mockResolvedValue({ data: pipelines } as any);
    vi.mocked(pipelinesService.moveItemToPipeline).mockResolvedValue({});
  });

  it('lists only stages of the selected pipeline and disables the current stage', async () => {
    render(<MoveItemModal open onOpenChange={vi.fn()} item={item} currentPipelineId="p1" onMoved={vi.fn()} />);

    await waitFor(() => expect(screen.getByTestId('move-stage-s2')).toBeInTheDocument());
    expect(screen.getByTestId('move-stage-s1')).toBeDisabled();
    expect(screen.queryByTestId('move-stage-s3')).not.toBeInTheDocument();
  });

  it('moves to a stage of another pipeline and reports the target', async () => {
    const onMoved = vi.fn();
    render(<MoveItemModal open onOpenChange={vi.fn()} item={item} currentPipelineId="p1" onMoved={onMoved} />);

    await waitFor(() => screen.getByTestId('move-pipeline-p2'));
    fireEvent.click(screen.getByTestId('move-pipeline-p2'));
    fireEvent.click(await screen.findByTestId('move-stage-s3'));
    fireEvent.click(screen.getByTestId('move-submit'));

    await waitFor(() =>
      expect(pipelinesService.moveItemToPipeline).toHaveBeenCalledWith({
        item_id: 'i1', pipeline_id: 'p1', target_pipeline_id: 'p2', to_stage_id: 's3', notes: '',
      }),
    );
    expect(onMoved).toHaveBeenCalledWith({ pipelineId: 'p2', pipelineName: 'Pós-venda', samePipeline: false });
  });

  it('shows the backend conflict message', async () => {
    vi.mocked(pipelinesService.moveItemToPipeline).mockRejectedValue({
      response: { status: 422, data: { error: { message: "Item already has an active journey in this pipeline in stage 'Onboarding'" } } },
    });
    render(<MoveItemModal open onOpenChange={vi.fn()} item={item} currentPipelineId="p1" onMoved={vi.fn()} />);

    await waitFor(() => screen.getByTestId('move-pipeline-p2'));
    fireEvent.click(screen.getByTestId('move-pipeline-p2'));
    fireEvent.click(await screen.findByTestId('move-stage-s3'));
    fireEvent.click(screen.getByTestId('move-submit'));

    expect(await screen.findByText(/already has an active journey/)).toBeInTheDocument();
  });
});
```

> Se `apiErrorMessage` não reconhecer o formato `{ error: { message } }`, abrir `src/utils/apiHelpers.ts:118` e ajustar o mock ao formato que ela lê (não mudar a função).

- [ ] **Step 3: Rodar e ver falhar**

Run: `cd evo-ai-frontend-community && npx vitest run src/components/pipelines/MoveItemModal.spec.tsx`
Expected: FAIL — `Failed to resolve import "./MoveItemModal"`.

- [ ] **Step 4: Implementar `MoveItemModal.tsx`**

Seletores como listas de botões (em vez de `Select` do design-system) — testáveis e bons em mobile.

```tsx
// [Traggi] "Mover para…": move o card para qualquer etapa de qualquer pipeline ativo.
import { useEffect, useMemo, useState } from 'react';
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Label,
  Textarea,
} from '@evoapi/design-system';
import { useLanguage } from '@/hooks/useLanguage';
import { pipelinesService } from '@/services/pipelines';
import { apiErrorMessage } from '@/utils/apiHelpers';
import type { Pipeline, PipelineItem } from '@/types/analytics';

export interface MoveItemTarget {
  pipelineId: string;
  pipelineName: string;
  samePipeline: boolean;
}

interface MoveItemModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  item: PipelineItem | null;
  currentPipelineId: string;
  onMoved: (target: MoveItemTarget) => void;
}

export default function MoveItemModal({ open, onOpenChange, item, currentPipelineId, onMoved }: MoveItemModalProps) {
  const { t } = useLanguage('pipelines');
  const [pipelines, setPipelines] = useState<Pipeline[]>([]);
  const [pipelineId, setPipelineId] = useState(currentPipelineId);
  const [stageId, setStageId] = useState<string | null>(null);
  const [notes, setNotes] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setPipelineId(currentPipelineId);
    setStageId(null);
    setNotes('');
    setError(null);
    pipelinesService
      .getPipelines({ is_active: true })
      .then(resp => setPipelines(resp?.data || []))
      .catch(() => setError(t('moveItem.loadError')));
  }, [open, currentPipelineId, t]);

  const selectedPipeline = useMemo(
    () => pipelines.find(p => String(p.id) === String(pipelineId)),
    [pipelines, pipelineId],
  );
  const samePipeline = String(pipelineId) === String(currentPipelineId);

  const handleSubmit = async () => {
    if (!item || !stageId || !selectedPipeline) return;
    setSaving(true);
    setError(null);
    try {
      await pipelinesService.moveItemToPipeline({
        item_id: item.id,
        pipeline_id: currentPipelineId,
        target_pipeline_id: String(selectedPipeline.id),
        to_stage_id: stageId,
        notes,
      });
      onMoved({ pipelineId: String(selectedPipeline.id), pipelineName: selectedPipeline.name, samePipeline });
      onOpenChange(false);
    } catch (err) {
      setError(apiErrorMessage(err) || t('moveItem.error'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('moveItem.title')}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <Label>{t('moveItem.pipeline')}</Label>
            <div className="flex flex-wrap gap-2">
              {pipelines.map(p => (
                <Button
                  key={p.id}
                  type="button"
                  size="sm"
                  variant={String(p.id) === String(pipelineId) ? 'default' : 'outline'}
                  data-testid={`move-pipeline-${p.id}`}
                  onClick={() => {
                    setPipelineId(String(p.id));
                    setStageId(null);
                  }}
                >
                  {p.name}
                </Button>
              ))}
            </div>
          </div>

          <div className="space-y-2">
            <Label>{t('moveItem.stage')}</Label>
            <div className="flex flex-col gap-1 max-h-60 overflow-y-auto">
              {(selectedPipeline?.stages || []).map(stage => {
                const isCurrent = samePipeline && String(stage.id) === String(item?.stage_id);
                return (
                  <Button
                    key={stage.id}
                    type="button"
                    size="sm"
                    variant={String(stage.id) === stageId ? 'default' : 'ghost'}
                    className="justify-start"
                    disabled={isCurrent}
                    data-testid={`move-stage-${stage.id}`}
                    onClick={() => setStageId(String(stage.id))}
                  >
                    <span className="w-2.5 h-2.5 rounded-full mr-2 shrink-0" style={{ backgroundColor: stage.color }} />
                    {stage.name}
                    {isCurrent && <span className="ml-2 text-xs text-muted-foreground">({t('moveItem.current')})</span>}
                  </Button>
                );
              })}
            </div>
          </div>

          <div className="space-y-2">
            <Label htmlFor="move-notes">{t('moveItem.notes')}</Label>
            <Textarea id="move-notes" value={notes} onChange={e => setNotes(e.target.value)} rows={2} />
          </div>

          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>
            {t('moveItem.cancel')}
          </Button>
          <Button data-testid="move-submit" onClick={handleSubmit} disabled={!stageId || saving}>
            {t('moveItem.submit')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

> Se `DialogHeader` não for exportado pelo `@evoapi/design-system`, remover o wrapper e deixar só `DialogTitle` (padrão de `EditItemModal.tsx`).

- [ ] **Step 5: i18n** — na raiz de `src/i18n/locales/pt-BR/pipelines.json` adicionar:

```json
  "moveItem": {
    "title": "Mover card",
    "pipeline": "Pipeline",
    "stage": "Etapa",
    "current": "atual",
    "notes": "Observação (opcional)",
    "cancel": "Cancelar",
    "submit": "Mover",
    "error": "Não foi possível mover o card",
    "loadError": "Não foi possível carregar os pipelines",
    "otherPipeline": "Outro pipeline…",
    "moveToOtherPipeline": "Mover para outro pipeline…",
    "movedTo": "Card movido para {{pipeline}}",
    "viewPipeline": "Ver pipeline"
  },
```

e em `src/i18n/locales/en/pipelines.json`:

```json
  "moveItem": {
    "title": "Move card",
    "pipeline": "Pipeline",
    "stage": "Stage",
    "current": "current",
    "notes": "Note (optional)",
    "cancel": "Cancel",
    "submit": "Move",
    "error": "Could not move the card",
    "loadError": "Could not load pipelines",
    "otherPipeline": "Other pipeline…",
    "moveToOtherPipeline": "Move to another pipeline…",
    "movedTo": "Card moved to {{pipeline}}",
    "viewPipeline": "View pipeline"
  },
```

(Confirmar a sintaxe de interpolação usada no projeto: `grep -n "{{" src/i18n/locales/pt-BR/pipelines.json | head -3`.)

- [ ] **Step 6: Rodar e ver passar**

Run: `npx vitest run src/components/pipelines/MoveItemModal.spec.tsx`
Expected: 3 passed.

- [ ] **Step 7: Commit**

```bash
git -C evo-ai-frontend-community add src/types/analytics/pipelines.ts src/services/pipelines/pipelinesService.ts src/components/pipelines/MoveItemModal.tsx src/components/pipelines/MoveItemModal.spec.tsx src/i18n/locales/pt-BR/pipelines.json src/i18n/locales/en/pipelines.json
git -C evo-ai-frontend-community commit -m "feat(pipelines): MoveItemModal para mover card entre pipelines

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 6: Frontend — ligar "Mover para…" no Kanban e na ficha do card

**Files:**
- Modify: `src/pages/Customer/Pipelines/PipelineKanban.tsx` (estado perto da linha 171; dropdown de mover ~linha 1318-1335; render dos modais ~linha 1619)
- Modify: `src/components/pipelines/EditItemModal.tsx` (props ~linha 79; seletor de etapa ~linha 380-397)

**Interfaces:**
- Consumes: `MoveItemModal`, `MoveItemTarget` (Task 5).
- Produces: nada consumido por tasks posteriores. `EditItemModal` ganha prop opcional `onMoveToOtherPipeline?: () => void`.

- [ ] **Step 1: Kanban — estado e handler.** Perto de `showEditItemModal` (~linha 174):

```tsx
  // [Traggi] "Mover para…" entre pipelines
  const [moveItemTarget, setMoveItemTarget] = useState<PipelineItem | null>(null);

  const handleItemMoved = async (target: MoveItemTarget) => {
    await loadPipelineData();
    if (target.samePipeline) {
      toast.success(t('kanban.messages.itemMoved'));
      return;
    }
    toast.success(t('moveItem.movedTo', { pipeline: target.pipelineName }), {
      action: { label: t('moveItem.viewPipeline'), onClick: () => navigate(`/pipelines/${target.pipelineId}`) },
    });
  };
```

Import: `import MoveItemModal, { type MoveItemTarget } from '@/components/pipelines/MoveItemModal';`

- [ ] **Step 2: Kanban — entrada no dropdown de mover.** O dropdown do ícone `ArrowLeftRight` só aparece com `moveTargets.length > 0`; trocar a condição e acrescentar o item ao final do `DropdownMenuContent`:

```tsx
                            {/* [Traggi] sempre visível: permite mover para outro pipeline */}
                            <DropdownMenu>
```

(remover o `{moveTargets.length > 0 && (` e o `)}` correspondente) e, depois do `moveTargets.map(...)`:

```tsx
                                  <DropdownMenuSeparator />
                                  <DropdownMenuItem onClick={() => setMoveItemTarget(item)}>
                                    <ArrowLeftRight className="w-4 h-4 mr-2" />
                                    {t('moveItem.otherPipeline')}
                                  </DropdownMenuItem>
```

- [ ] **Step 3: Kanban — renderizar o modal** junto do `RemoveItemModal` (~linha 1619):

```tsx
      {/* [Traggi] Mover para outro pipeline */}
      <MoveItemModal
        open={!!moveItemTarget}
        onOpenChange={open => !open && setMoveItemTarget(null)}
        item={moveItemTarget}
        currentPipelineId={pipelineId!}
        onMoved={handleItemMoved}
      />
```

- [ ] **Step 4: Ficha (`EditItemModal`)** — adicionar à interface de props:

```tsx
  /** [Traggi] abre o "Mover para outro pipeline…" */
  onMoveToOtherPipeline?: () => void;
```

desestruturar `onMoveToOtherPipeline` e, logo abaixo do `</Select>` do seletor de etapa (~linha 397):

```tsx
                    {onMoveToOtherPipeline && (
                      <Button type="button" variant="link" size="sm" className="px-0" onClick={onMoveToOtherPipeline}>
                        {t('moveItem.moveToOtherPipeline')}
                      </Button>
                    )}
```

No Kanban, no `<EditItemModal ...>` (~linha 1629) passar:

```tsx
          onMoveToOtherPipeline={() => {
            const current = selectedItemForEdit; // usar o nome real do estado do item em edição
            setShowEditItemModal(false);
            setMoveItemTarget(current);
          }}
```

(Confirmar o nome do estado do item em edição em `handleEditItem`, ~linha 685.)

- [ ] **Step 5: Verificar tipos, lint e specs existentes**

Run: `npx tsc -b --noEmit 2>&1 | head -30; npx eslint src/pages/Customer/Pipelines/PipelineKanban.tsx src/components/pipelines/EditItemModal.tsx src/components/pipelines/MoveItemModal.tsx; npx vitest run src/components/pipelines src/pages/Customer/Pipelines`
Expected: sem erros novos de tipo/lint; specs verdes.

- [ ] **Step 6: Commit**

```bash
git -C evo-ai-frontend-community add src/pages/Customer/Pipelines/PipelineKanban.tsx src/components/pipelines/EditItemModal.tsx
git -C evo-ai-frontend-community commit -m "feat(pipelines): 'Mover para outro pipeline' no menu do card e na ficha

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 7: Frontend — `SwitchInboxDialog` + serviço

**Files:**
- Modify: `src/services/chat/chatService.ts` (após `unarchiveConversation`/`archiveConversation`, ~linha 150)
- Create: `src/components/chat/switch-inbox/switchInboxUtils.ts`
- Create: `src/components/chat/switch-inbox/SwitchInboxDialog.tsx`
- Create: `src/components/chat/switch-inbox/index.ts`
- Modify: `src/i18n/locales/pt-BR/chat.json`, `src/i18n/locales/en/chat.json` (novo bloco `switchInbox` na raiz)
- Test: `src/components/chat/switch-inbox/SwitchInboxDialog.spec.tsx`

**Interfaces:**
- Consumes: `POST /conversations/:id/switch_inbox` (Task 4); `useAppDataStore().inboxes: Inbox[]` (`Inbox.connection_state`, `channel_type`, `name`, `phone_number`).
- Produces:
  - `chatService.switchInbox(conversationId: string, inboxId: string): Promise<ConversationResponse>`
  - `whatsappInboxes(inboxes: Inbox[]): Inbox[]`
  - `isInboxUnavailable(inbox?: Inbox | null): boolean`
  - `<SwitchInboxDialog open onOpenChange conversationId currentInboxId onSwitched={(conversation: Conversation) => void} />`

- [ ] **Step 1: Serviço** — em `chatService.ts`:

```ts
  // [Traggi] Troca o WhatsApp de saída da conversa, mantendo o histórico
  async switchInbox(conversationId: string, inboxId: string): Promise<ConversationResponse> {
    const response = await api.post(`/conversations/${conversationId}/switch_inbox`, { inbox_id: inboxId });
    return response.data;
  }
```

- [ ] **Step 2: Utils**

```ts
// [Traggi] Regras compartilhadas da troca de WhatsApp de saída.
import type { Inbox } from '@/types/channels/inbox';

const UNAVAILABLE_STATES = ['disconnected', 'error'];

export const whatsappInboxes = (inboxes: Inbox[]): Inbox[] =>
  inboxes.filter(inbox => inbox.channel_type === 'Channel::Whatsapp');

export const isInboxUnavailable = (inbox?: Inbox | null): boolean =>
  !!inbox?.connection_state && UNAVAILABLE_STATES.includes(inbox.connection_state);
```

- [ ] **Step 3: Escrever a spec (falhando)**

```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import SwitchInboxDialog from './SwitchInboxDialog';
import { isInboxUnavailable, whatsappInboxes } from './switchInboxUtils';
import chatService from '@/services/chat/chatService';

vi.mock('@/hooks/useLanguage', () => ({
  useLanguage: () => ({ t: (key: string) => key, currentLanguage: 'pt-BR' }),
}));
vi.mock('@/services/chat/chatService', () => ({ default: { switchInbox: vi.fn() } }));

const inboxes = [
  { id: 'a', name: 'Número A', channel_type: 'Channel::Whatsapp', connection_state: 'disconnected' },
  { id: 'b', name: 'Número B', channel_type: 'Channel::Whatsapp', connection_state: 'connected' },
  { id: 'c', name: 'Número C', channel_type: 'Channel::Whatsapp', connection_state: 'error' },
  { id: 'w', name: 'Site', channel_type: 'Channel::WebWidget' },
];
vi.mock('@/store/appDataStore', () => ({
  useAppDataStore: () => ({ inboxes }),
}));

describe('switchInboxUtils', () => {
  it('keeps only WhatsApp inboxes', () => {
    expect(whatsappInboxes(inboxes as any).map(i => i.id)).toEqual(['a', 'b', 'c']);
  });
  it('treats disconnected and error as unavailable, unknown as available', () => {
    expect(isInboxUnavailable({ connection_state: 'disconnected' } as any)).toBe(true);
    expect(isInboxUnavailable({ connection_state: 'error' } as any)).toBe(true);
    expect(isInboxUnavailable({ connection_state: 'unknown' } as any)).toBe(false);
    expect(isInboxUnavailable(undefined)).toBe(false);
  });
});

describe('SwitchInboxDialog', () => {
  beforeEach(() => {
    vi.mocked(chatService.switchInbox).mockResolvedValue({ data: { id: 'conv1', inbox_id: 'b' } } as any);
  });

  it('disables the current and unavailable numbers', () => {
    render(<SwitchInboxDialog open onOpenChange={vi.fn()} conversationId="conv1" currentInboxId="a" onSwitched={vi.fn()} />);

    expect(screen.getByTestId('switch-inbox-a')).toBeDisabled();
    expect(screen.getByTestId('switch-inbox-c')).toBeDisabled();
    expect(screen.getByTestId('switch-inbox-b')).not.toBeDisabled();
    expect(screen.queryByTestId('switch-inbox-w')).not.toBeInTheDocument();
  });

  it('confirms and switches to the chosen number', async () => {
    const onSwitched = vi.fn();
    render(<SwitchInboxDialog open onOpenChange={vi.fn()} conversationId="conv1" currentInboxId="a" onSwitched={onSwitched} />);

    fireEvent.click(screen.getByTestId('switch-inbox-b'));
    expect(chatService.switchInbox).not.toHaveBeenCalled();
    fireEvent.click(screen.getByTestId('switch-inbox-confirm'));

    await waitFor(() => expect(chatService.switchInbox).toHaveBeenCalledWith('conv1', 'b'));
    expect(onSwitched).toHaveBeenCalledWith({ id: 'conv1', inbox_id: 'b' });
  });
});
```

> Confirmar o export do chatService: `grep -n "export" src/services/chat/chatService.ts | tail -3` e `cat src/services/chat/index.ts`. Ajustar import e `vi.mock` para o formato real (default vs. nomeado) — no componente usar o mesmo formato.

- [ ] **Step 4: Rodar e ver falhar**

Run: `npx vitest run src/components/chat/switch-inbox`
Expected: FAIL — `Failed to resolve import "./SwitchInboxDialog"`.

- [ ] **Step 5: Implementar `SwitchInboxDialog.tsx`**

```tsx
// [Traggi] Escolhe outro WhatsApp para a conversa. O histórico continua na mesma conversa/card.
import { useState } from 'react';
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
} from '@evoapi/design-system';
import { toast } from 'sonner';
import { useLanguage } from '@/hooks/useLanguage';
import { useAppDataStore } from '@/store/appDataStore';
import chatService from '@/services/chat/chatService';
import { apiErrorMessage } from '@/utils/apiHelpers';
import type { Conversation } from '@/types/chat/api';
import { isInboxUnavailable, whatsappInboxes } from './switchInboxUtils';

interface SwitchInboxDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  conversationId: string;
  currentInboxId: string;
  onSwitched: (conversation: Conversation) => void;
}

export default function SwitchInboxDialog({
  open,
  onOpenChange,
  conversationId,
  currentInboxId,
  onSwitched,
}: SwitchInboxDialogProps) {
  const { t } = useLanguage('chat');
  const { inboxes } = useAppDataStore();
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const options = whatsappInboxes(inboxes);
  const selected = options.find(i => i.id === selectedId);

  const close = (value: boolean) => {
    if (!value) setSelectedId(null);
    onOpenChange(value);
  };

  const confirm = async () => {
    if (!selectedId) return;
    setSaving(true);
    try {
      const response = await chatService.switchInbox(conversationId, selectedId);
      onSwitched(response.data);
      toast.success(t('switchInbox.success', { name: selected?.name }));
      close(false);
    } catch (err) {
      toast.error(apiErrorMessage(err) || t('switchInbox.error'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogContent className="sm:max-w-md">
        <DialogTitle>{t('switchInbox.title')}</DialogTitle>

        {!selected ? (
          <div className="flex flex-col gap-1">
            {options.map(inbox => {
              const isCurrent = inbox.id === currentInboxId;
              const unavailable = isInboxUnavailable(inbox);
              return (
                <Button
                  key={inbox.id}
                  type="button"
                  variant="ghost"
                  className="justify-between"
                  disabled={isCurrent || unavailable}
                  data-testid={`switch-inbox-${inbox.id}`}
                  onClick={() => setSelectedId(inbox.id)}
                >
                  <span>
                    {inbox.name}
                    {inbox.phone_number && <span className="ml-2 text-xs text-muted-foreground">{inbox.phone_number}</span>}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {isCurrent
                      ? t('switchInbox.current')
                      : unavailable
                        ? t('switchInbox.disconnected')
                        : t('switchInbox.connected')}
                  </span>
                </Button>
              );
            })}
          </div>
        ) : (
          <p className="text-sm">{t('switchInbox.confirmText', { name: selected.name })}</p>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => (selected ? setSelectedId(null) : close(false))} disabled={saving}>
            {selected ? t('switchInbox.back') : t('switchInbox.cancel')}
          </Button>
          {selected && (
            <Button data-testid="switch-inbox-confirm" onClick={confirm} disabled={saving}>
              {t('switchInbox.confirm')}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

`index.ts`:

```ts
export { default as SwitchInboxDialog } from './SwitchInboxDialog';
export { isInboxUnavailable, whatsappInboxes } from './switchInboxUtils';
```

> Confirmar a lib de toast do projeto: `grep -rn "from 'sonner'" src | head -1` (o Kanban usa `toast`). Usar o mesmo import.

- [ ] **Step 6: i18n** — na raiz de `src/i18n/locales/pt-BR/chat.json`:

```json
  "switchInbox": {
    "title": "Trocar número de WhatsApp",
    "sendVia": "Enviar por:",
    "change": "Trocar",
    "current": "atual",
    "connected": "conectado",
    "disconnected": "desconectado",
    "confirmText": "As próximas mensagens sairão por {{name}}. O histórico continua nesta conversa.",
    "confirm": "Trocar número",
    "back": "Voltar",
    "cancel": "Cancelar",
    "success": "Conversa agora usa {{name}}",
    "error": "Não foi possível trocar o número",
    "disconnectedBanner": "Este número está desconectado.",
    "disconnectedAction": "Trocar número",
    "via": "via {{name}}",
    "cardAction": "Trocar número de WhatsApp…"
  },
```

e em `src/i18n/locales/en/chat.json`:

```json
  "switchInbox": {
    "title": "Change WhatsApp number",
    "sendVia": "Send via:",
    "change": "Change",
    "current": "current",
    "connected": "connected",
    "disconnected": "disconnected",
    "confirmText": "Next messages will be sent from {{name}}. History stays in this conversation.",
    "confirm": "Change number",
    "back": "Back",
    "cancel": "Cancel",
    "success": "Conversation now uses {{name}}",
    "error": "Could not change the number",
    "disconnectedBanner": "This number is disconnected.",
    "disconnectedAction": "Change number",
    "via": "via {{name}}",
    "cardAction": "Change WhatsApp number…"
  },
```

- [ ] **Step 7: Rodar e ver passar**

Run: `npx vitest run src/components/chat/switch-inbox`
Expected: 4 passed.

- [ ] **Step 8: Commit**

```bash
git -C evo-ai-frontend-community add src/services/chat/chatService.ts src/components/chat/switch-inbox src/i18n/locales/pt-BR/chat.json src/i18n/locales/en/chat.json
git -C evo-ai-frontend-community commit -m "feat(chat): SwitchInboxDialog para trocar o WhatsApp de saída

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 8: Frontend — barra "Enviar por" no chat e ação no card

**Files:**
- Create: `src/components/chat/switch-inbox/SendViaBar.tsx`
- Modify: `src/components/chat/switch-inbox/index.ts`
- Modify: `src/components/chat/chat-area/ChatArea.tsx` (acima de `<MessageInput`, ~linha 404)
- Modify: `src/pages/Customer/Pipelines/PipelineKanban.tsx` (menu ⋮ do card, ~linha 1352)
- Test: `src/components/chat/switch-inbox/SendViaBar.spec.tsx`

**Interfaces:**
- Consumes: `SwitchInboxDialog`, `whatsappInboxes`, `isInboxUnavailable` (Task 7); `useChatContext().conversations.updateConversation(conv)` (existente — confirmar em `src/contexts/chat/ChatContext.tsx:192` como `conversations` é exposto).
- Produces: `<SendViaBar conversationId currentInboxId isWhatsApp onSwitched />`.

- [ ] **Step 1: Escrever a spec (falhando)**

```tsx
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import SendViaBar from './SendViaBar';

vi.mock('@/hooks/useLanguage', () => ({
  useLanguage: () => ({ t: (key: string) => key, currentLanguage: 'pt-BR' }),
}));
vi.mock('./SwitchInboxDialog', () => ({ default: () => null }));

let inboxes: any[] = [];
vi.mock('@/store/appDataStore', () => ({ useAppDataStore: () => ({ inboxes }) }));

describe('SendViaBar', () => {
  it('is hidden when the user has only one WhatsApp number', () => {
    inboxes = [{ id: 'a', name: 'Número A', channel_type: 'Channel::Whatsapp', connection_state: 'connected' }];
    const { container } = render(<SendViaBar conversationId="c" currentInboxId="a" isWhatsApp onSwitched={vi.fn()} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('is hidden for non-WhatsApp conversations', () => {
    inboxes = [
      { id: 'a', name: 'A', channel_type: 'Channel::Whatsapp' },
      { id: 'b', name: 'B', channel_type: 'Channel::Whatsapp' },
    ];
    const { container } = render(<SendViaBar conversationId="c" currentInboxId="w" isWhatsApp={false} onSwitched={vi.fn()} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('shows the current number and a disconnected warning', () => {
    inboxes = [
      { id: 'a', name: 'Número A', channel_type: 'Channel::Whatsapp', connection_state: 'disconnected' },
      { id: 'b', name: 'Número B', channel_type: 'Channel::Whatsapp', connection_state: 'connected' },
    ];
    render(<SendViaBar conversationId="c" currentInboxId="a" isWhatsApp onSwitched={vi.fn()} />);
    expect(screen.getByText('Número A')).toBeInTheDocument();
    expect(screen.getByText('switchInbox.disconnectedBanner')).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `npx vitest run src/components/chat/switch-inbox/SendViaBar.spec.tsx`
Expected: FAIL — `Failed to resolve import "./SendViaBar"`.

- [ ] **Step 3: Implementar `SendViaBar.tsx`**

```tsx
// [Traggi] "Enviar por: <número>" acima do campo de mensagem + aviso de número desconectado.
import { useState } from 'react';
import { Button } from '@evoapi/design-system';
import { AlertTriangle, Smartphone } from 'lucide-react';
import { useLanguage } from '@/hooks/useLanguage';
import { useAppDataStore } from '@/store/appDataStore';
import type { Conversation } from '@/types/chat/api';
import SwitchInboxDialog from './SwitchInboxDialog';
import { isInboxUnavailable, whatsappInboxes } from './switchInboxUtils';

interface SendViaBarProps {
  conversationId: string;
  currentInboxId: string;
  isWhatsApp: boolean;
  onSwitched: (conversation: Conversation) => void;
}

export default function SendViaBar({ conversationId, currentInboxId, isWhatsApp, onSwitched }: SendViaBarProps) {
  const { t } = useLanguage('chat');
  const { inboxes } = useAppDataStore();
  const [open, setOpen] = useState(false);
  const options = whatsappInboxes(inboxes);
  const current = options.find(i => i.id === currentInboxId);

  if (!isWhatsApp || options.length < 2) return null;

  const unavailable = isInboxUnavailable(current);

  return (
    <>
      <div
        className={`flex items-center gap-2 px-4 py-1.5 text-xs border-t border-border ${
          unavailable ? 'bg-amber-50 text-amber-900 dark:bg-amber-950/40 dark:text-amber-200' : 'text-muted-foreground'
        }`}
      >
        {unavailable ? <AlertTriangle className="w-3.5 h-3.5" /> : <Smartphone className="w-3.5 h-3.5" />}
        {unavailable && <span>{t('switchInbox.disconnectedBanner')}</span>}
        <span>{t('switchInbox.sendVia')}</span>
        <span className="font-medium text-foreground">{current?.name}</span>
        <Button variant="link" size="sm" className="h-auto p-0 text-xs" onClick={() => setOpen(true)}>
          {unavailable ? t('switchInbox.disconnectedAction') : t('switchInbox.change')}
        </Button>
      </div>
      <SwitchInboxDialog
        open={open}
        onOpenChange={setOpen}
        conversationId={conversationId}
        currentInboxId={currentInboxId}
        onSwitched={onSwitched}
      />
    </>
  );
}
```

Em `index.ts` acrescentar `export { default as SendViaBar } from './SendViaBar';`.

- [ ] **Step 4: Rodar e ver passar**

Run: `npx vitest run src/components/chat/switch-inbox`
Expected: 7 passed.

- [ ] **Step 5: Ligar no `ChatArea`.** Importar `import { SendViaBar } from '../switch-inbox';`, pegar `conversations` do contexto (`const { messages, websocket, conversations } = useChatContext();` — confirmar que o contexto expõe `conversations`; se não, usar o hook que `ChatContext.tsx` usa para `updateConversation`). Dentro do `<div className="flex-shrink-0 w-full">`, antes de `<MessageInput`:

```tsx
        {/* [Traggi] troca do WhatsApp de saída */}
        {selectedConversationId && selectedConversation?.inbox_id && (
          <SendViaBar
            conversationId={selectedConversationId}
            currentInboxId={selectedConversation.inbox_id}
            isWhatsApp={isWhatsAppChannel}
            onSwitched={updated => conversations.updateConversation(updated)}
          />
        )}
```

- [ ] **Step 6: Ação no card do Kanban.** Estado junto de `moveItemTarget`:

```tsx
  // [Traggi] trocar número de WhatsApp pelo card
  const [switchInboxItem, setSwitchInboxItem] = useState<PipelineItem | null>(null);
```

No menu ⋮, logo após o item "Abrir conversa":

```tsx
                                {item.conversation?.inbox?.channel_type === 'Channel::Whatsapp' && (
                                  <DropdownMenuItem onClick={() => setSwitchInboxItem(item)}>
                                    <Smartphone className="h-4 w-4 mr-2" />
                                    {tChat('switchInbox.cardAction')}
                                  </DropdownMenuItem>
                                )}
```

com `const { t: tChat } = useLanguage('chat');` no topo do componente e `Smartphone` no import de `lucide-react`. Junto do `MoveItemModal`:

```tsx
      {switchInboxItem?.conversation && (
        <SwitchInboxDialog
          open
          onOpenChange={open => !open && setSwitchInboxItem(null)}
          conversationId={switchInboxItem.item_id}
          currentInboxId={switchInboxItem.conversation.inbox?.id ?? ''}
          onSwitched={() => {
            setSwitchInboxItem(null);
            loadPipelineData();
          }}
        />
      )}
```

com `import { SwitchInboxDialog } from '@/components/chat/switch-inbox';`. (Confirmar que `item.item_id` é o id da conversa para cards `type === 'conversation'`; se não, usar `item.conversation.id`/`uuid` — o endpoint aceita ambos.) Garantir que o Kanban tenha inboxes carregados: se `useAppDataStore().inboxes` estiver vazio nessa página, chamar `fetchInboxes(false)` num `useEffect` quando `switchInboxItem` for definido.

- [ ] **Step 7: Verificar**

Run: `npx tsc -b --noEmit 2>&1 | head -30; npx eslint src/components/chat/switch-inbox src/components/chat/chat-area/ChatArea.tsx src/pages/Customer/Pipelines/PipelineKanban.tsx; npx vitest run src/components/chat src/pages/Customer/Pipelines`
Expected: sem erros novos; specs verdes.

- [ ] **Step 8: Commit**

```bash
git -C evo-ai-frontend-community add src/components/chat/switch-inbox src/components/chat/chat-area/ChatArea.tsx src/pages/Customer/Pipelines/PipelineKanban.tsx
git -C evo-ai-frontend-community commit -m "feat(chat): barra 'Enviar por' e troca de número pelo card

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 9: Frontend — etiqueta "via <número>" nas mensagens

**Files:**
- Modify: `src/types/chat/api.ts` (interface `Message`, ~linha 224)
- Create: `src/components/chat/messages/utils/viaInbox.ts`
- Modify: `src/components/chat/messages/MessageBubble.tsx` (props linha 36; timestamp `default` ~linhas 389 e 550)
- Modify: `src/components/chat/messages/MessageList.tsx` (props linha 54; `<MessageBubble` ~linha 637)
- Modify: `src/components/chat/chat-area/ChatArea.tsx` (`<MessageList` ~linha 379)
- Test: `src/components/chat/messages/utils/viaInbox.spec.ts`

**Interfaces:**
- Consumes: `inbox_id` nas mensagens (Task 4); `inboxesById: Map<string, Inbox>` já existente no `ChatArea`.
- Produces: `viaInboxName(messageInboxId: string | undefined, currentInboxId: string | undefined, inboxNames: Map<string, string>): string | null`; prop `viaInboxName?: string | null` no `MessageBubble`; props `currentInboxId?: string` e `inboxNames?: Map<string, string>` no `MessageList`.

- [ ] **Step 1: Escrever a spec (falhando)**

```ts
import { describe, expect, it } from 'vitest';
import { viaInboxName } from './viaInbox';

const names = new Map([['a', 'Número A'], ['b', 'Número B']]);

describe('viaInboxName', () => {
  it('returns the name when the message came through another inbox', () => {
    expect(viaInboxName('a', 'b', names)).toBe('Número A');
  });
  it('returns null for messages on the current inbox', () => {
    expect(viaInboxName('b', 'b', names)).toBeNull();
  });
  it('returns null when data is missing', () => {
    expect(viaInboxName(undefined, 'b', names)).toBeNull();
    expect(viaInboxName('a', undefined, names)).toBeNull();
    expect(viaInboxName('z', 'b', names)).toBeNull();
  });
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `npx vitest run src/components/chat/messages/utils/viaInbox.spec.ts`
Expected: FAIL — import não resolvido.

- [ ] **Step 3: Implementar**

`viaInbox.ts`:

```ts
// [Traggi] Nome do número por onde a mensagem passou, quando difere do número atual da conversa.
export const viaInboxName = (
  messageInboxId: string | undefined,
  currentInboxId: string | undefined,
  inboxNames: Map<string, string>,
): string | null => {
  if (!messageInboxId || !currentInboxId || messageInboxId === currentInboxId) return null;
  return inboxNames.get(messageInboxId) ?? null;
};
```

`api.ts`, na interface `Message` após `conversation_id: string;`:

```ts
  inbox_id?: string; // [Traggi] número por onde a mensagem passou
```

`MessageList.tsx` — em `MessageListProps`:

```ts
  currentInboxId?: string; // [Traggi]
  inboxNames?: Map<string, string>; // [Traggi]
```

desestruturar ambos, importar `viaInboxName` de `./utils/viaInbox`, e no `<MessageBubble` principal (~linha 637):

```tsx
                    viaInboxName={inboxNames ? viaInboxName(message.inbox_id, currentInboxId, inboxNames) : null}
```

`MessageBubble.tsx` — em `MessageBubbleProps`: `viaInboxName?: string | null; // [Traggi]`; desestruturar; e imediatamente antes de cada `{showTimestamp && timestampVariant === 'default' && (` (as duas ocorrências):

```tsx
              {viaInboxName && (
                <span className="text-[10px] text-muted-foreground italic mr-1">
                  {t('switchInbox.via', { name: viaInboxName })}
                </span>
              )}
```

(Confirmar que `MessageBubble` já usa `useLanguage('chat')`; se usar outro namespace, chamar `useLanguage('chat')` separado como `tChat`.)

`ChatArea.tsx` — perto de `inboxesById`:

```tsx
  // [Traggi] nomes dos números para a etiqueta "via"
  const inboxNames = useMemo(() => new Map(inboxes.map(item => [item.id, item.name])), [inboxes]);
```

e no `<MessageList`:

```tsx
            currentInboxId={selectedConversation?.inbox_id}
            inboxNames={inboxNames}
```

- [ ] **Step 4: Rodar e verificar**

Run: `npx vitest run src/components/chat/messages; npx tsc -b --noEmit 2>&1 | head -30; npx eslint src/components/chat/messages src/components/chat/chat-area/ChatArea.tsx src/types/chat/api.ts`
Expected: specs verdes (incluindo `MessageList.spec.tsx` existente), sem erros novos.

- [ ] **Step 5: Commit**

```bash
git -C evo-ai-frontend-community add src/types/chat/api.ts src/components/chat/messages src/components/chat/chat-area/ChatArea.tsx
git -C evo-ai-frontend-community commit -m "feat(chat): etiqueta 'via <número>' em mensagens de outro WhatsApp

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 10: Verificação final

- [ ] **Step 1: Frontend completo** — `cd evo-ai-frontend-community && npx vitest run && npm run build`. Expected: tudo verde; build ok.
- [ ] **Step 2: Backend no CI** — (com push autorizado) `gh run watch --repo lucianoagenda/evo-ai-crm-community` do workflow `Traggi - specs`. Expected: todos os exemplos verdes.
- [ ] **Step 3: Atualizar o spec** com os desvios registrados neste plano: (a) "Mover para…" vive no dropdown de mover do Kanban e na ficha (`EditItemModal`), não em `PipelineItemCard`; (b) após mover, o Kanban recarrega (padrão existente) em vez de atualização otimista; (c) serializer expõe só `inbox_id` — o nome vem do store de inboxes no frontend; (d) destino "indisponível" = `disconnected`/`error` (`unknown` permitido). Commit no backend.
- [ ] **Step 4: Teste manual (após deploy em ambiente de homologação)** — mover card para outro pipeline pelo menu e pela ficha; trocar número numa conversa Evolution; enviar mensagem e confirmar saída pelo número novo; responder do celular do cliente no número novo e confirmar que cai na mesma conversa; ver etiqueta "via Número A" nas mensagens antigas.
