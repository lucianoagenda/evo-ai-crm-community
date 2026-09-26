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
    target_id = target.id
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?) do |policy|
      policy.record.id != target_id
    end

    move!(new_stage_id: target_stage.id, target_pipeline_id: target.id)

    # Convenção da app: negação do Pundit vira 401 (RequestExceptionHandler), como em pipeline_items_write_authz_rbac_spec.
    expect(response).to have_http_status(:unauthorized)
    expect(item.reload.pipeline_id).to eq(source.id)
  end

  it 'keeps the same-pipeline behaviour when target_pipeline_id is the current pipeline' do
    other_stage = source.pipeline_stages.create!(name: 'Proposta', position: 2)

    move!(new_stage_id: other_stage.id, target_pipeline_id: source.id)

    expect(response).to have_http_status(:ok)
    expect(item.reload.pipeline_stage_id).to eq(other_stage.id)
  end
end
