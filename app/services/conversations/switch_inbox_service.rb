# frozen_string_literal: true

# [Traggi] Troca o número de WhatsApp de uma conversa (ex.: número caiu/banido).
# A conversa continua a mesma — mensagens antigas mantêm o inbox_id por onde
# passaram — e o card do pipeline continua apontando para ela.
class Conversations::SwitchInboxService
  UNAVAILABLE_STATES = %w[disconnected error].freeze
  # Provedores cujo serviço de entrada grava o source_id de celular BR sempre com 13 dígitos
  # (EvolutionHandlers::MessagesUpsert#set_individual_contact → normalised_brazil_mobile_number).
  BR_NINTH_DIGIT_PROVIDERS = %w[evolution].freeze

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
      @conversation.update!(inbox: @target_inbox, contact_inbox: target_contact_inbox)
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
    raise Error, :target_has_open_conversation if open_conversation_on_target?
  end

  def whatsapp?(inbox)
    inbox&.channel_type == 'Channel::Whatsapp'
  end

  def unavailable?(inbox)
    Channels::ConnectionStateResolver.call(inbox.channel)[:state].in?(UNAVAILABLE_STATES)
  end

  # Os serviços de entrada pegam a conversa aberta mais recente do ContactInbox; com duas
  # abertas, a resposta do cliente cairia numa delas de forma imprevisível.
  def open_conversation_on_target?
    Conversation.where(inbox_id: @target_inbox.id, contact_id: @conversation.contact_id)
                .where.not(status: :resolved)
                .exists?
  end

  # Reaproveita o ContactInbox que o contato já tem no número de destino (qualquer formato de
  # source_id); senão cria um no mesmo formato que o serviço de entrada do provedor usa.
  def target_contact_inbox
    existing = @conversation.contact.contact_inboxes.where(inbox_id: @target_inbox.id).order(:created_at).last
    return existing if existing

    ContactInboxBuilder.new(contact: @conversation.contact, inbox: @target_inbox, source_id: target_source_id).perform
  end

  def target_source_id
    return nil unless @target_inbox.channel.provider.in?(BR_NINTH_DIGIT_PROVIDERS)

    digits = @conversation.contact.phone_number.delete('+')
    return digits unless digits.start_with?('55') && digits.length == 12

    "#{digits[0, 4]}9#{digits[4..]}"
  end

  def activity_content(from_inbox)
    I18n.t(
      'conversations.activity.inbox_switched',
      from: inbox_label(from_inbox),
      to: inbox_label(@target_inbox),
      user_name: @user&.name,
      default: 'Canal alterado de %{from} para %{to} por %{user_name}' # rubocop:disable Style/FormatStringToken
    )
  end

  # Inbox#name é sanitizado para identificador; o nome legível fica em display_name.
  def inbox_label(inbox)
    inbox.display_name.presence || inbox.name
  end
end
