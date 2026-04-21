class Whatsapp::OneoffCampaignService
  # Raised quando o pré-check de saldo bloqueia o disparo (MKT-25).
  # A mensagem traz o texto já formatado pelo Platform para exibição ao admin.
  class BillingPrecheckBlockedError < StandardError
    attr_reader :user_message, :http_status, :payload

    def initialize(user_message:, http_status:, payload: nil)
      @user_message = user_message
      @http_status = http_status
      @payload = payload
      super(user_message)
    end
  end

  pattr_initialize [:campaign!]

  def perform
    validate_campaign!
    audience_contacts = eligible_contacts(extract_audience_labels)
    ensure_billing_precheck!(audience_contacts.size)
    # marks campaign completed so that other jobs won't pick it up
    campaign.completed!
    process_audience(audience_contacts)
  end

  private

  delegate :inbox, to: :campaign
  delegate :channel, to: :inbox

  def validate_campaign_type!
    raise "Invalid campaign #{campaign.id}" unless whatsapp_campaign? && campaign.one_off?
  end

  def whatsapp_campaign?
    campaign.inbox.inbox_type == 'Whatsapp'
  end

  def validate_campaign_status!
    raise 'Completed Campaign' if campaign.completed?
  end

  def validate_provider!
    raise 'WhatsApp Cloud provider required' if channel.provider != 'whatsapp_cloud'
  end

  def validate_feature_flag!
    raise 'WhatsApp campaigns feature not enabled' unless campaign.account.feature_enabled?(:whatsapp_campaign)
  end

  def validate_campaign!
    validate_campaign_type!
    validate_campaign_status!
    validate_provider!
    validate_feature_flag!
  end

  def extract_audience_labels
    audience_label_ids = campaign.audience.select { |audience| audience['type'] == 'Label' }.pluck('id')
    campaign.account.labels.where(id: audience_label_ids).pluck(:title)
  end

  def process_contact(contact)
    Rails.logger.info "Processing contact: #{contact.name} (#{contact.phone_number})"

    if contact.phone_number.blank?
      Rails.logger.info "Skipping contact #{contact.name} - no phone number"
      return
    end

    if campaign.template_params.blank?
      Rails.logger.error "Skipping contact #{contact.name} - no template_params found for WhatsApp campaign"
      return
    end

    if create_conversations?
      send_via_conversation(contact)
    else
      send_whatsapp_template_message(to: contact.phone_number, contact: contact)
    end
  end

  def eligible_contacts(audience_labels)
    campaign.account.contacts.tagged_with(audience_labels, any: true)
  end

  def process_audience(contacts)
    Rails.logger.info "Processing #{contacts.count} contacts for campaign #{campaign.id}"

    contacts.each { |contact| process_contact(contact) }

    Rails.logger.info "Campaign #{campaign.id} processing completed"
  end

  def ensure_billing_precheck!(audience_size)
    phone_number_id = channel.provider_config&.dig('phone_number_id')

    if phone_number_id.blank?
      Rails.logger.error "Campaign #{campaign.id}: missing phone_number_id in provider_config — blocking dispatch"
      raise BillingPrecheckBlockedError.new(
        user_message: Whatsapp::BillingPrecheckService::GENERIC_ERROR_MESSAGE,
        http_status: :missing_phone_number_id
      )
    end

    result = Whatsapp::BillingPrecheckService.new(
      phone_number_id: phone_number_id,
      audience_size: audience_size
    ).call

    return if result.allowed?

    persist_precheck_failure!(result)
    raise BillingPrecheckBlockedError.new(
      user_message: result.user_message,
      http_status: result.http_status,
      payload: result.payload
    )
  end

  def persist_precheck_failure!(result)
    # Marca a campanha como completed para não ser reprocessada pelo TriggerScheduledItemsJob
    # e registra o motivo em trigger_rules (jsonb) para a UI exibir ao admin.
    updated_rules = (campaign.trigger_rules || {}).deep_dup
    updated_rules['precheck_error'] = {
      'user_message' => result.user_message,
      'http_status' => result.http_status.to_s,
      'payload' => result.payload,
      'blocked_at' => Time.current.iso8601
    }
    campaign.update_columns(trigger_rules: updated_rules, campaign_status: Campaign.campaign_statuses[:completed])
  rescue StandardError => e
    Rails.logger.error "Campaign #{campaign.id}: failed to persist precheck error: #{e.message}"
  end

  def create_conversations?
    campaign.trigger_rules&.dig('create_conversations') == true
  end

  def send_via_conversation(contact)
    resolved_params = resolve_contact_variables(campaign.template_params, contact)

    # Find or create contact_inbox
    contact_inbox = ContactInboxBuilder.new(
      contact: contact,
      inbox: inbox
    ).perform

    # Find open conversation or create new one
    conversation = contact_inbox.conversations.where(status: [:open, :pending]).last
    conversation ||= Conversation.create!(
      account_id: campaign.account_id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      contact_inbox_id: contact_inbox.id
    )

    # Build rendered message content
    rendered = campaign.message.presence || ''
    resolved_params.dig('processed_params', 'body')&.each do |key, value|
      rendered = rendered.gsub(/\{\{#{Regexp.escape(key)}\}\}/, value.to_s)
      rendered = rendered.gsub(/\[Nome\]|\[Sobrenome\]|\[Email\]|\[Telefone\]|\[Empresa\]|\[Cidade\]|\[Identificador\]/, value.to_s)
    end

    # Create outgoing message with template_params — Chatwoot dispatches via SendOnWhatsappService
    conversation.messages.create!(
      account_id: campaign.account_id,
      inbox_id: inbox.id,
      message_type: :outgoing,
      content: rendered,
      additional_attributes: { 'template_params' => resolved_params }
    )

    Rails.logger.info "Campaign #{campaign.id}: Created conversation message for #{contact.name}"
  rescue StandardError => e
    Rails.logger.error "Campaign #{campaign.id}: Failed to create conversation for #{contact.name}: #{e.message}"
    nil
  end

  def send_whatsapp_template_message(to:, contact: nil)
    resolved_params = resolve_contact_variables(campaign.template_params, contact)

    processor = Whatsapp::TemplateProcessorService.new(
      channel: channel,
      template_params: resolved_params
    )

    name, namespace, lang_code, processed_parameters = processor.call

    return if name.blank?

    channel.send_template(to, {
                            name: name,
                            namespace: namespace,
                            lang_code: lang_code,
                            parameters: processed_parameters
                          }, nil)

  rescue StandardError => e
    Rails.logger.error "Failed to send WhatsApp template message to #{to}: #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join('\n')}"
    # continue processing remaining contacts
    nil
  end

  def resolve_contact_variables(template_params, contact)
    return template_params if contact.nil?

    resolved = template_params.deep_dup
    body_params = resolved.dig('processed_params', 'body')
    return resolved unless body_params.is_a?(Hash)

    body_params.each do |key, value|
      next unless value.is_a?(String) && value.start_with?('{{contact.')

      field = value.delete_prefix('{{contact.').delete_suffix('}}')
      body_params[key] = resolve_contact_field(contact, field)
    end

    resolved
  end

  def resolve_contact_field(contact, field)
    case field
    when 'name' then contact.name.presence || ''
    when 'last_name' then contact.last_name.presence || ''
    when 'email' then contact.email.presence || ''
    when 'phone_number' then contact.phone_number.presence || ''
    when 'identifier' then contact.identifier.presence || ''
    when 'company' then contact.additional_attributes&.dig('company_name').presence || contact.additional_attributes&.dig('company').presence || ''
    when 'city' then contact.additional_attributes&.dig('city').presence || ''
    else ''
    end
  end
end
