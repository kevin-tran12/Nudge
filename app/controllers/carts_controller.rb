class CartsController < ApplicationController
  include Identity::EnsuresShoppingSession

  def show
    session = current_or_bootstrapped_shopping_session
    return render_unavailable unless session

    @snapshot = Cart::Service.new.snapshot(shopping_session: session)
  end

  private
    def render_unavailable
      @error_title = "Cart unavailable"
      @error_message = "We couldn't start a shopping session. Please try again."
      render :error, status: :service_unavailable
    end
end
