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
