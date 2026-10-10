# frozen_string_literal: true

# [Traggi] Painel do Traggi na barra lateral da conversa: situação do contato
# no agente do Traggi (lead ou cliente) e os botões devolver/reabrir/encerrar/
# opt-out. O telefone vem sempre do contato da conversa, nunca do navegador.
# Spec: docs/superpowers/specs/2026-10-10-painel-traggi-design.md
class Api::V1::Conversations::TraggiController < Api::V1::Conversations::BaseController
  require_permissions({
    show: 'conversations.read',
    acao: 'conversations.update'
  })

  def show
    return success_response(data: { configured: false }) unless client.configured?
    return success_response(data: { configured: true, tipo: 'nenhum', acoes: [], motivos: [] }) if phone.blank?

    success_response(data: client.situacao(phone).merge('configured' => true))
  rescue Traggi::Client::Error => e
    traggi_error(e)
  end

  def acao
    unless client.configured?
      return error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, 'Traggi não configurado no CRM.',
                            status: :unprocessable_entity)
    end

    result = client.acao(
      telefone: phone,
      tipo: params[:tipo].to_s,
      id: params[:id].to_i,
      acao: params[:acao].to_s,
      observacao: params[:observacao].presence,
      motivo_categoria: params[:motivo_categoria].presence,
      usuario: Current.user&.name
    )
    success_response(data: result.merge('configured' => true))
  rescue Traggi::Client::Error => e
    traggi_error(e)
  end

  private

  def client
    @client ||= Traggi::Client.new
  end

  def phone
    @conversation.contact&.phone_number.presence
  end

  def traggi_error(error)
    if error.status >= 500
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, error.message, status: :bad_gateway)
    else
      error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, error.message, status: :unprocessable_entity)
    end
  end
end
