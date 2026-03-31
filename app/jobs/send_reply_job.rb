class SendReplyJob < ApplicationJob
  queue_as :high

  CHANNEL_SERVICES = {
    'Channel::TwitterProfile' => ::Twitter::SendOnTwitterService,
    'Channel::TwilioSms' => ::Twilio::SendOnTwilioService,
    'Channel::Line' => ::Line::SendOnLineService,
    'Channel::Telegram' => ::Telegram::SendOnTelegramService,
    'Channel::Whatsapp' => ::Whatsapp::SendOnWhatsappService,
    'Channel::Sms' => ::Sms::SendOnSmsService,
    'Channel::Instagram' => ::Instagram::SendOnInstagramService,
    'Channel::Tiktok' => ::Tiktok::SendOnTiktokService,
    'Channel::Email' => ::Email::SendOnEmailService,
    'Channel::WebWidget' => ::Messages::SendEmailNotificationService,
    'Channel::Api' => ::Messages::SendEmailNotificationService
  }.freeze

  MAX_ATTACHMENT_RETRIES = 3
  LOCK_TIMEOUT = 60
  LOCK_POLL_INTERVAL = 0.3
  MAX_LOCK_WAIT = 30

  def perform(message_id, retry_count = 0)
    message = Message.find(message_id)

    # Safety net: if attachments exist but files aren't ready yet, retry
    if message.attachments.any? && message.attachments.any? { |a| !a.file.attached? }
      if retry_count < MAX_ATTACHMENT_RETRIES
        self.class.set(wait: 500.milliseconds).perform_later(message_id, retry_count + 1)
        return
      end
      Rails.logger.error "SendReplyJob: Attachments not ready after #{MAX_ATTACHMENT_RETRIES} retries for message #{message_id}"
    end

    send_with_conversation_lock(message)
  end

  private

  def send_with_conversation_lock(message)
    lock_key = "send_reply:conversation:#{message.conversation_id}"
    lock_manager = Redis::LockManager.new

    # Wait for any previous message in this conversation to finish sending
    waited = 0
    while lock_manager.locked?(lock_key) && waited < MAX_LOCK_WAIT
      sleep LOCK_POLL_INTERVAL
      waited += LOCK_POLL_INTERVAL
    end

    # Acquire lock (with TTL as safety net against deadlocks)
    unless lock_manager.lock(lock_key, LOCK_TIMEOUT)
      Rails.logger.warn "SendReplyJob: Could not acquire lock for conversation #{message.conversation_id}, sending anyway"
    end

    begin
      send_to_channel(message)
    ensure
      lock_manager.unlock(lock_key)
    end
  end

  def send_to_channel(message)
    channel_name = message.conversation.inbox.channel.class.to_s

    return send_on_facebook_page(message) if channel_name == 'Channel::FacebookPage'

    service_class = CHANNEL_SERVICES[channel_name]
    return unless service_class

    service_class.new(message: message).perform
  end

  def send_on_facebook_page(message)
    if message.conversation.additional_attributes['type'] == 'instagram_direct_message'
      ::Instagram::Messenger::SendOnInstagramService.new(message: message).perform
    else
      ::Facebook::SendOnFacebookService.new(message: message).perform
    end
  end
end
