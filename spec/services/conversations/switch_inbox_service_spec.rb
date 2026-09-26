# frozen_string_literal: true

require 'rails_helper'

# [Traggi] Troca do WhatsApp de saída mantendo a conversa (e o card) intactos.
RSpec.describe Conversations::SwitchInboxService do
  def wa_inbox(name, connection: 'open', provider: 'evolution')
    channel = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: provider,
                                    provider_config: { 'api_url' => 'http://evo.test', 'admin_token' => 'x' },
                                    provider_connection: { 'connection' => connection })
    channel.save(validate: false)
    Inbox.create!(name: name, channel: channel)
  end

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
  end

  let(:user) { User.create!(name: 'Ana', email: "ana-#{SecureRandom.hex(4)}@example.com") }
  let(:old_inbox) { wa_inbox('Número A') }
  let(:new_inbox) { wa_inbox('Número B') }
  let(:contact) { Contact.create!(name: 'Cliente', phone_number: "+55219#{rand(10_000_000..99_999_999)}") }
  let(:old_ci) { ContactInbox.create!(inbox: old_inbox, contact: contact, source_id: contact.phone_number.delete('+')) }
  let(:conversation) { Conversation.create!(inbox: old_inbox, contact: contact, contact_inbox: old_ci) }

  def perform(target = new_inbox)
    described_class.new(conversation: conversation, target_inbox: target, user: user).perform
  end

  it 're-points the conversation to the new inbox and keeps previous messages' do
    msg = conversation.messages.create!(inbox_id: old_inbox.id, message_type: :incoming, content: 'oi', sender: contact)

    result = perform

    expect(result.inbox_id).to eq(new_inbox.id)
    expect(result.contact_inbox.inbox_id).to eq(new_inbox.id)
    expect(msg.reload.inbox_id).to eq(old_inbox.id)
    expect(result.messages.where(message_type: :activity).last.content)
      .to eq('Canal alterado de Número A para Número B por Ana')
  end

  it 'reuses the existing contact inbox on the target number' do
    existing = ContactInbox.create!(inbox: new_inbox, contact: contact, source_id: contact.phone_number.delete('+'))
    conversation

    expect { perform }.not_to change(ContactInbox, :count)
    expect(conversation.reload.contact_inbox_id).to eq(existing.id)
  end

  it 'makes a reply on the new number land in the same open conversation' do
    perform
    new_ci = ContactInbox.find_by!(inbox: new_inbox, contact: contact)

    # Mesma busca de Whatsapp::IncomingMessageBaseService#set_conversation.
    expect(new_ci.conversations.where.not(status: :resolved).last).to eq(conversation)
  end

  it 'dispatches conversation.updated after switching' do
    expect(conversation).to receive(:dispatch_conversation_updated_event)
    perform
  end

  it 'refuses the current inbox' do
    expect { perform(old_inbox) }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:same_inbox) }
  end

  it 'refuses a disconnected target' do
    down = wa_inbox('Caído', connection: 'close')
    expect { perform(down) }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:target_disconnected) }
  end

  it 'refuses a non-WhatsApp target' do
    web = Inbox.create!(name: 'Site', channel: Channel::WebWidget.create!(website_url: 'https://x.example.com'))
    expect { perform(web) }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:target_not_whatsapp) }
  end

  it 'refuses a non-WhatsApp conversation' do
    web = Inbox.create!(name: 'Site', channel: Channel::WebWidget.create!(website_url: 'https://y.example.com'))
    web_ci = ContactInbox.create!(inbox: web, contact: contact, source_id: SecureRandom.hex(4))
    web_conv = Conversation.create!(inbox: web, contact: contact, contact_inbox: web_ci)

    expect do
      described_class.new(conversation: web_conv, target_inbox: new_inbox, user: user).perform
    end.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:not_whatsapp_conversation) }
  end

  it 'refuses a contact without phone number' do
    conversation
    contact.update_columns(phone_number: nil) # rubocop:disable Rails/SkipsModelValidations
    expect { perform }.to raise_error(described_class::Error) { |e| expect(e.reason).to eq(:contact_without_phone) }
    expect(conversation.reload.inbox_id).to eq(old_inbox.id)
  end

  it 'rolls back the switch when the activity message cannot be created' do
    conversation # cria antes do stub
    # A única mensagem criada no fluxo é a de atividade.
    allow_any_instance_of(Message).to receive(:valid?).and_return(false)

    expect { perform }.to raise_error(ActiveRecord::RecordInvalid)
    expect(conversation.reload.inbox_id).to eq(old_inbox.id)
  end
end
