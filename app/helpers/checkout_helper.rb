module CheckoutHelper
  def checkout_money(amount_minor, currency)
    major, minor = amount_minor.divmod(100)
    "#{currency} #{number_with_delimiter(major)}.#{format('%02d', minor)}"
  end

  def checkout_payment_status_label(session)
    case session.payment_status
    when "paid" then "Paid"
    when "no_payment_required" then "No payment required"
    when "unpaid" then "Unpaid"
    else "Unknown"
    end
  end
end
