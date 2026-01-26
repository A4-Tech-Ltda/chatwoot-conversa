# frozen_string_literal: true

# =============================================================================
# ConversaComAgente - Automated Platform Setup
# =============================================================================
# Creates SuperAdmin and PlatformApp for automated deployment.
#
# Usage:
#   bundle exec rake chatwoot:setup_platform
#   bundle exec rake chatwoot:setup_platform[admin@example.com,SecurePassword123!]
#   ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD=xxx bundle exec rake chatwoot:setup_platform
#
# Environment variables:
#   ADMIN_EMAIL    - SuperAdmin email (default: admin@conversacomagente.com.br)
#   ADMIN_PASSWORD - SuperAdmin password (default: auto-generated)
#   APP_NAME       - Platform app name (default: ConversaComAgente)
#
# Output (JSON):
#   {
#     "super_admin": { "email": "...", "password": "..." },
#     "platform_app": { "name": "...", "token": "..." }
#   }
# =============================================================================

namespace :chatwoot do
  desc 'Setup SuperAdmin and PlatformApp for ConversaComAgente'
  task :setup_platform, [:email, :password] => :environment do |_task, args|
    # Get credentials from args or environment
    admin_email = args[:email] || ENV.fetch('ADMIN_EMAIL', 'admin@conversacomagente.com.br')
    admin_password = args[:password] || ENV.fetch('ADMIN_PASSWORD', nil)
    app_name = ENV.fetch('APP_NAME', 'ConversaComAgente')

    # Generate password if not provided
    admin_password ||= SecureRandom.alphanumeric(16) + '!'

    result = {
      super_admin: {},
      platform_app: {},
      created: { super_admin: false, platform_app: false }
    }

    # Create or find SuperAdmin
    super_admin = SuperAdmin.find_by(email: admin_email)

    if super_admin
      Rails.logger.info "SuperAdmin already exists: #{admin_email}"
      result[:super_admin] = {
        email: admin_email,
        password: '(existing - not changed)',
        status: 'existing'
      }
    else
      super_admin = SuperAdmin.new(
        email: admin_email,
        password: admin_password,
        name: 'Platform Admin',
        confirmed_at: Time.current
      )

      if super_admin.save
        Rails.logger.info "SuperAdmin created: #{admin_email}"
        result[:super_admin] = {
          email: admin_email,
          password: admin_password,
          status: 'created'
        }
        result[:created][:super_admin] = true
      else
        Rails.logger.error "Failed to create SuperAdmin: #{super_admin.errors.full_messages.join(', ')}"
        result[:super_admin] = {
          email: admin_email,
          error: super_admin.errors.full_messages.join(', '),
          status: 'failed'
        }
      end
    end

    # Create or find PlatformApp
    platform_app = PlatformApp.find_by(name: app_name)

    if platform_app
      Rails.logger.info "PlatformApp already exists: #{app_name}"
      result[:platform_app] = {
        name: app_name,
        token: platform_app.access_token&.token,
        status: 'existing'
      }
    else
      platform_app = PlatformApp.new(name: app_name)

      if platform_app.save
        Rails.logger.info "PlatformApp created: #{app_name}"
        result[:platform_app] = {
          name: app_name,
          token: platform_app.access_token&.token,
          status: 'created'
        }
        result[:created][:platform_app] = true
      else
        Rails.logger.error "Failed to create PlatformApp: #{platform_app.errors.full_messages.join(', ')}"
        result[:platform_app] = {
          name: app_name,
          error: platform_app.errors.full_messages.join(', '),
          status: 'failed'
        }
      end
    end

    # Output JSON for script consumption
    puts result.to_json
  end

  desc 'Show current platform configuration'
  task platform_info: :environment do
    result = {
      super_admins: SuperAdmin.pluck(:email),
      platform_apps: PlatformApp.includes(:access_token).map do |app|
        {
          name: app.name,
          token: app.access_token&.token,
          created_at: app.created_at
        }
      end
    }

    puts JSON.pretty_generate(result)
  end

  desc 'Reset platform token (regenerate)'
  task :reset_platform_token, [:app_name] => :environment do |_task, args|
    app_name = args[:app_name] || ENV.fetch('APP_NAME', 'ConversaComAgente')

    platform_app = PlatformApp.find_by(name: app_name)

    if platform_app.nil?
      puts JSON.generate({ error: "PlatformApp '#{app_name}' not found" })
      exit 1
    end

    # Destroy old token and create new one
    platform_app.access_token&.destroy
    platform_app.create_access_token

    puts JSON.generate({
                         name: app_name,
                         token: platform_app.access_token.token,
                         status: 'regenerated'
                       })
  end
end
