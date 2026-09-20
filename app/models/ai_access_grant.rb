class AiAccessGrant < ApplicationRecord
  STATUSES = %w[active expired revoked terminated].freeze

  belongs_to :shopping_session, inverse_of: :ai_access_grants
  belongs_to :disclosure_consent_record, class_name: "ConsentRecord"
  belongs_to :turnstile_verification, optional: true, inverse_of: :ai_access_grant

  validates :status, inclusion: { in: STATUSES }

  def active_at?(time)
    status == "active" && issued_at <= time && time < expires_at
  end
end
