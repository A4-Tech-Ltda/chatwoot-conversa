# loading installation configs
GlobalConfig.clear_cache
ConfigLoader.new.process

## Seeds productions
if Rails.env.production?
  # Setup Onboarding flow
  Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING, true)
end

## Seeds for Local Development (disabled - we don't want sample data)
# unless Rails.env.production?
#   ... sample Acme Inc/Org data removed ...
# end

## =============================================================================
## ConversaComAgente Platform Setup (runs in ALL environments)
## =============================================================================
## Creates the SuperAdmin and PlatformApp with fixed credentials for automated
## deployment. These values match the production configuration.
##
## Usage: bundle exec rails db:seed
## =============================================================================

Rails.logger.info '[ConversaComAgente] Setting up platform integration...'

# Platform Admin credentials (fixed for automated deployment)
PLATFORM_ADMIN_EMAIL = 'admin@conversacomagente.com.br'.freeze
PLATFORM_ADMIN_PASSWORD = 'h2xJbqtp2FNk!'.freeze
PLATFORM_APP_NAME = 'ConversaComAgente'.freeze
PLATFORM_APP_TOKEN = 'xQXEs4LXZgqHzrayNu8f2dQE'.freeze

# Create or find SuperAdmin
platform_admin = SuperAdmin.find_by(email: PLATFORM_ADMIN_EMAIL)
if platform_admin
  Rails.logger.info "[ConversaComAgente] SuperAdmin already exists: #{PLATFORM_ADMIN_EMAIL}"
else
  platform_admin = SuperAdmin.new(
    email: PLATFORM_ADMIN_EMAIL,
    password: PLATFORM_ADMIN_PASSWORD,
    name: 'Platform Admin'
  )
  platform_admin.skip_confirmation!
  platform_admin.save!
  Rails.logger.info "[ConversaComAgente] SuperAdmin created: #{PLATFORM_ADMIN_EMAIL}"
end

# Create or find PlatformApp with fixed token
platform_app = PlatformApp.find_by(name: PLATFORM_APP_NAME)
if platform_app
  # Ensure token matches expected value
  if platform_app.access_token&.token == PLATFORM_APP_TOKEN
    Rails.logger.info "[ConversaComAgente] PlatformApp already exists with correct token"
  else
    Rails.logger.info "[ConversaComAgente] Updating PlatformApp token to fixed value"
    platform_app.access_token&.destroy
    AccessToken.create!(owner: platform_app, token: PLATFORM_APP_TOKEN)
  end
else
  # Create PlatformApp (after_create callback will create a random token)
  platform_app = PlatformApp.create!(name: PLATFORM_APP_NAME)

  # Replace the auto-generated token with our fixed token
  platform_app.access_token&.destroy
  AccessToken.create!(owner: platform_app, token: PLATFORM_APP_TOKEN)
  Rails.logger.info "[ConversaComAgente] PlatformApp created: #{PLATFORM_APP_NAME}"
end

Rails.logger.info "[ConversaComAgente] Platform setup complete!"
Rails.logger.info "[ConversaComAgente] SuperAdmin: #{PLATFORM_ADMIN_EMAIL}"
Rails.logger.info "[ConversaComAgente] Platform Token: #{PLATFORM_APP_TOKEN}"
