# frozen_string_literal: true

require 'rails_helper'

# [Traggi] Painel do Traggi na barra lateral da conversa.
RSpec.describe 'Traggi panel on a conversation', type: :request do
  let(:user) { User.create!(name: 'Ana', email: "ana-#{SecureRandom.hex(4)}@example.com") }
  let(:inbox) do
    channel = Channel::Api.create!
    Inbox.create!(name: 'API', channel: channel)
  end
  let(:phone) { "+55489#{rand(10_000_000..99_999_999)}" }
  let(:contact) { Contact.create!(name: 'Joana', phone_number: phone) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:client) { instance_double(Traggi::Client, configured?: true) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::V1::Conversations::TraggiController).to receive(:check_show_permission!).and_return(true)
    allow_any_instance_of(Api::V1::Conversations::TraggiController).to receive(:check_acao_permission!).and_return(true)
    allow_any_instance_of(InboxPolicy).to receive(:show?).and_return(true)
    allow(Traggi::Client).to receive(:new).and_return(client)
  end

  after { Current.reset }

  describe 'GET /api/v1/conversations/:id/traggi' do
    it 'returns the Traggi situation for the contact phone' do
      allow(client).to receive(:situacao).with(phone).and_return('tipo' => 'lead', 'id' => 3, 'acoes' => ['devolver'])

      get "/api/v1/conversations/#{conversation.id}/traggi", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']).to include('configured' => true, 'tipo' => 'lead', 'id' => 3)
    end

    it 'says it is not configured without the Traggi env vars' do
      allow(client).to receive(:configured?).and_return(false)

      get "/api/v1/conversations/#{conversation.id}/traggi", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']).to eq('configured' => false)
    end

    it 'does not call the Traggi when the contact has no phone' do
      contact.update_column(:phone_number, nil)
      expect(client).not_to receive(:situacao)

      get "/api/v1/conversations/#{conversation.id}/traggi", as: :json

      expect(response.parsed_body['data']).to include('configured' => true, 'tipo' => 'nenhum')
    end

    it 'turns a Traggi outage into 502' do
      allow(client).to receive(:situacao).and_raise(Traggi::Client::Error.new('Traggi fora do ar', 502))

      get "/api/v1/conversations/#{conversation.id}/traggi", as: :json

      expect(response).to have_http_status(:bad_gateway)
    end
  end

  describe 'POST /api/v1/conversations/:id/traggi/acao' do
    it 'sends the action with the conversation phone and the user name' do
      expect(client).to receive(:acao).with(
        telefone: phone, tipo: 'lead', id: 3, acao: 'encerrar', observacao: 'ok', motivo_categoria: nil, usuario: 'Ana'
      ).and_return('tipo' => 'lead', 'status' => 'encerrado')

      post "/api/v1/conversations/#{conversation.id}/traggi/acao",
           params: { tipo: 'lead', id: 3, acao: 'encerrar', observacao: 'ok', telefone: '+5500000000000' }, as: :json

      expect(response).to have_http_status(:ok), response.body.to_s[0, 600]
      expect(response.parsed_body['data']).to include('configured' => true, 'status' => 'encerrado')
    end

    it 'returns the Traggi refusal as 422 with its message' do
      allow(client).to receive(:acao).and_raise(Traggi::Client::Error.new('Essa ação não vale para a situação atual.', 409))

      post "/api/v1/conversations/#{conversation.id}/traggi/acao", params: { tipo: 'lead', id: 3, acao: 'devolver' }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['code']).to eq('BUSINESS_RULE_VIOLATION')
      expect(response.parsed_body['error']['message']).to eq('Essa ação não vale para a situação atual.')
    end

    it 'refuses when the Traggi is not configured' do
      allow(client).to receive(:configured?).and_return(false)

      post "/api/v1/conversations/#{conversation.id}/traggi/acao", params: { tipo: 'lead', id: 3, acao: 'devolver' }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
