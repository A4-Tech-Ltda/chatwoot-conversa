# loading installation configs
GlobalConfig.clear_cache
ConfigLoader.new.process

## Seeds productions
if Rails.env.production?
  # Setup Onboarding flow
  Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING, true)
end

## Seeds for Local Development
unless Rails.env.production?

  # Enables creating additional accounts from dashboard
  installation_config = InstallationConfig.find_by(name: 'CREATE_NEW_ACCOUNT_FROM_DASHBOARD')
  installation_config.value = true
  installation_config.save!
  GlobalConfig.clear_cache

  account = Account.create!(
    name: 'Acme Inc'
  )

  secondary_account = Account.create!(
    name: 'Acme Org'
  )

  user = User.new(name: 'John', email: 'john@acme.inc', password: 'Password1!', type: 'SuperAdmin')
  user.skip_confirmation!
  user.save!

  AccountUser.create!(
    account_id: account.id,
    user_id: user.id,
    role: :administrator
  )

  AccountUser.create!(
    account_id: secondary_account.id,
    user_id: user.id,
    role: :administrator
  )

  web_widget = Channel::WebWidget.create!(account: account, website_url: 'https://acme.inc')

  inbox = Inbox.create!(channel: web_widget, account: account, name: 'Acme Support')
  InboxMember.create!(user: user, inbox: inbox)

  contact_inbox = ContactInboxWithContactBuilder.new(
    source_id: user.id,
    inbox: inbox,
    hmac_verified: true,
    contact_attributes: { name: 'jane', email: 'jane@example.com', phone_number: '+2320000' }
  ).perform

  conversation = Conversation.create!(
    account: account,
    inbox: inbox,
    status: :open,
    assignee: user,
    contact: contact_inbox.contact,
    contact_inbox: contact_inbox,
    additional_attributes: {}
  )

  # sample email collect
  Seeders::MessageSeeder.create_sample_email_collect_message conversation

  Message.create!(content: 'Hello', account: account, inbox: inbox, conversation: conversation, sender: contact_inbox.contact,
                  message_type: :incoming)

  # sample location message
  #
  location_message = Message.new(content: 'location', account: account, inbox: inbox, sender: contact_inbox.contact, conversation: conversation,
                                 message_type: :incoming)
  location_message.attachments.new(
    account_id: account.id,
    file_type: 'location',
    coordinates_lat: 37.7893768,
    coordinates_long: -122.3895553,
    fallback_title: 'Bay Bridge, San Francisco, CA, USA'
  )
  location_message.save!

  # sample card
  Seeders::MessageSeeder.create_sample_cards_message conversation
  # input select
  Seeders::MessageSeeder.create_sample_input_select_message conversation
  # form
  Seeders::MessageSeeder.create_sample_form_message conversation
  # articles
  Seeders::MessageSeeder.create_sample_articles_message conversation
  # csat
  Seeders::MessageSeeder.create_sample_csat_collect_message conversation

  CannedResponse.create!(account: account, short_code: 'start', content: 'Hello welcome to chatwoot.')
end

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
