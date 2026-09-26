# frozen_string_literal: true

require 'rails_helper'

# [Traggi] Após trocar o WhatsApp da conversa, a janela de 24h da Cloud API é
# por número: mensagens recebidas no número antigo não abrem janela no novo.
RSpec.describe Conversations::MessageWindowService do
  def wa_inbox(name)
    channel = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: 'whatsapp_cloud',
                                    provider_config: { 'api_key' => 'x', 'phone_number_id' => '1', 'business_account_id' => '1' })
    channel.save(validate: false)
    Inbox.create!(name: name, channel: channel)
  end

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
    allow(Rails.env).to receive(:development?).and_return(false)
  end

  let(:old_inbox) { wa_inbox('Antigo') }
  let(:new_inbox) { wa_inbox('Novo') }
  let(:contact) { Contact.create!(name: 'Cliente', phone_number: "+55219#{rand(10_000_000..99_999_999)}") }
  let(:old_ci) { ContactInbox.create!(inbox: old_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:new_ci) { ContactInbox.create!(inbox: new_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:conversation) { Conversation.create!(inbox: old_inbox, contact: contact, contact_inbox: old_ci) }

  it 'ignores incoming messages received on a previous inbox' do
    conversation.messages.create!(inbox_id: old_inbox.id, message_type: :incoming, content: 'oi', sender: contact)
    conversation.update!(inbox: new_inbox, contact_inbox: new_ci)

    expect(described_class.new(conversation.reload).can_reply?).to be(false)
  end

  it 'opens the window with an incoming message on the current inbox' do
    conversation.update!(inbox: new_inbox, contact_inbox: new_ci)
    conversation.messages.create!(inbox_id: new_inbox.id, message_type: :incoming, content: 'oi', sender: contact)

    expect(described_class.new(conversation.reload).can_reply?).to be(true)
  end
end
