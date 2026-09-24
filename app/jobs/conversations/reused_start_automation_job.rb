# [Traggi] Dispara SÓ as regras de automação "conversation_created" para uma
# conversa que foi reaproveitada ao "Iniciar conversa" (ver
# Conversation#handle_reused_by_agent_start!). Não passa pelo dispatcher
# completo de propósito: notificações, webhooks externos e broadcast de
# "nova conversa" continuam valendo só para conversas realmente novas.
class Conversations::ReusedStartAutomationJob < ApplicationJob
  queue_as :critical

  def perform(conversation)
    event = Events::Base.new(
      Events::Types::CONVERSATION_CREATED,
      Time.zone.now,
      conversation: conversation,
      changed_attributes: nil,
      reused_conversation: true
    )
    AutomationRuleListener.instance.conversation_created(event)
  end
end
