class TurnstileVerification < ApplicationRecord
  belongs_to :shopping_session, inverse_of: :turnstile_verifications
  has_one :ai_access_grant, inverse_of: :turnstile_verification

  def fresh_at?(time)
    success && challenge_timestamp <= time && validated_at <= time &&
      challenge_timestamp >= time - 5.minutes && time < expires_at
  end
end
