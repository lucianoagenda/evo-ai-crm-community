# frozen_string_literal: true

require 'httparty'

module Traggi
  # [Traggi] Cliente da API do agente do Traggi para o painel na conversa.
  # A chave fica só no servidor (ENV); o navegador fala apenas com o CRM.
  # Spec: docs/superpowers/specs/2026-10-10-painel-traggi-design.md
  class Client
    TIMEOUT = 5

    class Error < StandardError
      attr_reader :status

      def initialize(message, status)
        super(message)
        @status = status
      end
    end

    # Mesmo padrão do proxy /traggi-api do frontend (docker-entrypoint.sh).
    DEFAULT_URL = 'https://app.traggi.com.br'

    def initialize(url: ENV.fetch('TRAGGI_API_URL', ''), key: ENV.fetch('TRAGGI_API_KEY', ''))
      @url = (url.to_s.strip.presence || DEFAULT_URL).chomp('/')
      @key = key.to_s.strip
    end

    def configured?
      @url.present? && @key.present?
    end

    def situacao(telefone)
      request { HTTParty.get("#{@url}/api/agente/crm/situacao", query: { telefone: telefone }, headers: headers, timeout: TIMEOUT) }
    end

    def acao(payload)
      request do
        HTTParty.post("#{@url}/api/agente/crm/acao", body: payload.to_json,
                                                    headers: headers.merge('Content-Type' => 'application/json'), timeout: TIMEOUT)
      end
    end

    private

    def headers
      { 'Api-Key' => @key, 'Accept' => 'application/json' }
    end

    def request
      response = yield
      body = parse(response.body)
      return body if response.code == 200 && body.is_a?(Hash)

      raise Error.new(traggi_message(body, response.code), 502) if body.nil? || response.code >= 500

      raise Error.new(traggi_message(body, response.code), response.code)
    rescue HTTParty::Error, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      raise Error.new("Não foi possível falar com o Traggi (#{e.class.name}).", 502)
    end

    def parse(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      nil
    end

    def traggi_message(body, code)
      message = body['erro'] if body.is_a?(Hash)
      message.presence || "Resposta inesperada do Traggi (HTTP #{code})."
    end
  end
end
