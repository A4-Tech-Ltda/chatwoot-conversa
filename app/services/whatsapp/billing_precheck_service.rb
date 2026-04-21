class Whatsapp::BillingPrecheckService
  # Pré-check de saldo para disparo de campanhas WhatsApp (MKT-25).
  # Consulta o Platform interno para validar se o creator tem créditos
  # suficientes antes de iniciar o processamento da audiência.
  #
  # Sempre fail-closed: qualquer erro de rede, HTTP não previsto ou
  # configuração ausente bloqueia o disparo.
  class ConfigurationError < StandardError; end

  # Result object retornado por #call.
  Result = Struct.new(:allowed, :user_message, :http_status, :payload, keyword_init: true) do
    def allowed?
      allowed == true
    end
  end

  GENERIC_ERROR_MESSAGE = 'Não foi possível validar o saldo agora, tente novamente em instantes.'.freeze
  DEFAULT_TIMEOUT_SECONDS = 5

  pattr_initialize [:phone_number_id!, :audience_size!]

  def call
    validate_config!

    response = post_precheck
    handle_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error, SocketError, Errno::ECONNREFUSED => e
    log_error("connection error talking to platform: #{e.class} #{e.message}")
    blocked_result(http_status: :network_error, user_message: GENERIC_ERROR_MESSAGE)
  end

  private

  def validate_config!
    raise ConfigurationError, 'PLATFORM_INTERNAL_URL is not configured' if platform_url.blank?
    raise ConfigurationError, 'PLATFORM_API_KEY is not configured' if api_key.blank?
  end

  def platform_url
    ENV.fetch('PLATFORM_INTERNAL_URL', nil)
  end

  def api_key
    ENV.fetch('PLATFORM_API_KEY', nil)
  end

  def post_precheck
    log_info("posting precheck phone_number_id=#{phone_number_id} audience_size=#{audience_size}")

    HTTParty.post(
      "#{platform_url.chomp('/')}/api/internal/waba-billing/precheck",
      headers: {
        'X-Platform-Api-Key' => api_key,
        'Content-Type' => 'application/json',
        'Accept' => 'application/json'
      },
      body: { phone_number_id: phone_number_id, audience_size: audience_size }.to_json,
      timeout: DEFAULT_TIMEOUT_SECONDS
    )
  end

  def handle_response(response)
    status = response.code
    body = safe_parse(response)

    log_info("platform response status=#{status} body=#{body.inspect}")

    case status
    when 200
      handle_ok(body)
    when 402
      handle_payment_required(body)
    when 404
      log_warn("agent not mapped for phone_number_id=#{phone_number_id}")
      blocked_result(http_status: status, user_message: GENERIC_ERROR_MESSAGE, payload: body)
    when 401
      log_error("unauthorized on platform precheck — check PLATFORM_API_KEY")
      raise ConfigurationError, 'Platform rejected PLATFORM_API_KEY (401)'
    else
      log_error("unexpected platform status=#{status}")
      blocked_result(http_status: status, user_message: GENERIC_ERROR_MESSAGE, payload: body)
    end
  end

  def handle_ok(body)
    if body['allowed'] == true
      Result.new(allowed: true, user_message: nil, http_status: 200, payload: body)
    else
      # Defesa extra: platform retornou 200 mas sem allowed=true.
      log_error("platform returned 200 without allowed=true, blocking. body=#{body.inspect}")
      blocked_result(http_status: 200, user_message: body['user_message'].presence || GENERIC_ERROR_MESSAGE, payload: body)
    end
  end

  def handle_payment_required(body)
    message = body['user_message'].presence || GENERIC_ERROR_MESSAGE
    blocked_result(http_status: 402, user_message: message, payload: body)
  end

  def blocked_result(http_status:, user_message:, payload: nil)
    Result.new(allowed: false, user_message: user_message, http_status: http_status, payload: payload)
  end

  def safe_parse(response)
    parsed = response.parsed_response
    parsed.is_a?(Hash) ? parsed : {}
  rescue StandardError
    {}
  end

  def log_info(msg)
    Rails.logger.tagged('waba_billing_precheck') { Rails.logger.info(msg) }
  end

  def log_warn(msg)
    Rails.logger.tagged('waba_billing_precheck') { Rails.logger.warn(msg) }
  end

  def log_error(msg)
    Rails.logger.tagged('waba_billing_precheck') { Rails.logger.error(msg) }
  end
end
