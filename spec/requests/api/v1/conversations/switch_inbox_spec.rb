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
    allow_any_instance_of(Api::V1::ConversationsController).to receive(:check_switch_inbox_permission!).and_return(true)
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
    blocked_id = new_inbox.id
    allow_any_instance_of(InboxPolicy).to receive(:show?) { |policy| policy.record.id != blocked_id }

    post "/api/v1/conversations/#{conversation.id}/switch_inbox", params: { inbox_id: new_inbox.id }, as: :json

    # Convenção da app: negação do Pundit vira 401 (RequestExceptionHandler), como em pipeline_items_write_authz_rbac_spec.
    expect(response).to have_http_status(:unauthorized)
    expect(conversation.reload.inbox_id).to eq(old_inbox.id)
  end

  it 'returns 404 for an unknown inbox' do
    post "/api/v1/conversations/#{conversation.id}/switch_inbox", params: { inbox_id: SecureRandom.uuid }, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'exposes inbox_id on serialized messages' do
    msg = conversation.messages.create!(inbox_id: old_inbox.id, message_type: :incoming, content: 'oi', sender: contact)

    expect(MessageSerializer.serialize(msg)['inbox_id']).to eq(old_inbox.id)
  end
end
