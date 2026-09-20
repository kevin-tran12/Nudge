# ELEVENLABS-SPECIFIC: removable provider integration; do not place domain logic here.
#
# Reads ElevenLabs credentials from ENV exactly once, at the Rails boundary. Every
# other file must depend on Rails.application.config.x.eleven_labs, never on ENV
# directly. Missing credentials never crash boot: fixture mode (the default in every
# deployment except production, see Integrations::ElevenLabs::ModePolicy) does not
# need them, and live mode fails closed with :missing_credentials on first use.
#
# Assignment is deferred to after_initialize: autoloading for app/-managed
# constants (Integrations::ElevenLabs::Config) is not yet available while
# config/initializers/*.rb run, only once the application has finished booting.
Rails.application.config.after_initialize do
  Rails.application.config.x.eleven_labs = Integrations::ElevenLabs::Config.new(
    api_key: ENV["ELEVENLABS_API_KEY"].presence,
    agent_id: ENV["ELEVENLABS_AGENT_ID"].presence,
    tool_secret: ENV["ELEVENLABS_TOOL_SECRET"].presence,
    webhook_secret: ENV["ELEVENLABS_WEBHOOK_SECRET"].presence
  ).freeze
end
