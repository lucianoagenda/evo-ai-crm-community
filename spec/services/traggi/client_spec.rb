# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# [Traggi] Cliente HTTP da API do agente do Traggi (painel na conversa).
RSpec.describe Traggi::Client do
  let(:base) { 'https://traggi.test' }

  around do |example|
    old = ENV.to_h.slice('TRAGGI_API_URL', 'TRAGGI_API_KEY')
    ENV['TRAGGI_API_URL'] = "#{base}/"
    ENV['TRAGGI_API_KEY'] = 'chave-secreta'
    example.run
  ensure
    %w[TRAGGI_API_URL TRAGGI_API_KEY].each { |k| old.key?(k) ? ENV[k] = old[k] : ENV.delete(k) }
  end

  it 'is configured only with url and key' do
    expect(described_class.new).to be_configured
    ENV['TRAGGI_API_KEY'] = ''
    expect(described_class.new).not_to be_configured
  end

  it 'defaults to the production Traggi url, like the frontend proxy' do
    ENV.delete('TRAGGI_API_URL')
    stub = stub_request(:get, 'https://app.traggi.com.br/api/agente/crm/situacao?telefone=55').to_return(status: 200, body: '{"tipo":"nenhum"}')

    described_class.new.situacao('55')

    expect(stub).to have_been_requested
  end

  it 'fetches the situation of a phone with the Api-Key header' do
    stub = stub_request(:get, "#{base}/api/agente/crm/situacao")
           .with(query: { telefone: '5548991000001' }, headers: { 'Api-Key' => 'chave-secreta' })
           .to_return(status: 200, body: '{"tipo":"lead","id":3,"acoes":["devolver"]}',
                      headers: { 'Content-Type' => 'application/json' })

    result = described_class.new.situacao('5548991000001')

    expect(stub).to have_been_requested
    expect(result).to include('tipo' => 'lead', 'id' => 3, 'acoes' => ['devolver'])
  end

  it 'posts an action as JSON' do
    stub = stub_request(:post, "#{base}/api/agente/crm/acao")
           .with(body: { telefone: '55', tipo: 'lead', id: 3, acao: 'devolver' }.to_json,
                 headers: { 'Api-Key' => 'chave-secreta', 'Content-Type' => 'application/json' })
           .to_return(status: 200, body: '{"tipo":"lead","status":"em_conversa"}')

    result = described_class.new.acao(telefone: '55', tipo: 'lead', id: 3, acao: 'devolver')

    expect(stub).to have_been_requested
    expect(result['status']).to eq('em_conversa')
  end

  it 'raises with the Traggi message and status on a refusal' do
    stub_request(:post, "#{base}/api/agente/crm/acao")
      .to_return(status: 409, body: '{"erro":"Essa ação não vale para a situação atual."}')

    expect { described_class.new.acao(acao: 'devolver') }.to raise_error(Traggi::Client::Error) { |e|
      expect(e.status).to eq(409)
      expect(e.message).to eq('Essa ação não vale para a situação atual.')
    }
  end

  it 'raises a gateway error on timeout' do
    stub_request(:get, /traggi\.test/).to_timeout

    expect { described_class.new.situacao('55') }.to raise_error(Traggi::Client::Error) { |e|
      expect(e.status).to eq(502)
    }
  end

  it 'raises a gateway error on a non-JSON answer' do
    stub_request(:get, /traggi\.test/).to_return(status: 500, body: '<html>erro</html>')

    expect { described_class.new.situacao('55') }.to raise_error(Traggi::Client::Error) { |e|
      expect(e.status).to eq(502)
    }
  end
end
