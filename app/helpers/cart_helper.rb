module CartHelper
  def cart_line_item_price_label(line_item)
    return "Price unknown" unless line_item.price_known

    money_label(line_item.unit_amount_minor, line_item.currency)
  end

  def cart_line_item_total_label(line_item)
    return "Price unknown" unless line_item.price_known

    money_label(line_item.line_total_minor, line_item.currency)
  end

  def cart_total_label(total)
    return "Total unavailable -- one or more item prices are unknown" unless total.state == :known

    "Total: #{money_label(total.amount_minor, total.currency)}"
  end

  private
    def money_label(amount_minor, currency)
      major, minor = amount_minor.divmod(100)
      "#{currency} #{number_with_delimiter(major)}.#{format('%02d', minor)}"
    end
end
