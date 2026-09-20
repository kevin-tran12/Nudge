class CartItemsController < ApplicationController
  include Identity::EnsuresShoppingSession

  ERROR_COPY = {
    "quantity_invalid" => "Quantity must be a positive whole number.",
    "not_found" => "That item is no longer in your cart.",
    "mutation_conflict" => "That action was already submitted with different details. Please refresh and try again.",
    "variant_unavailable" => "That item is temporarily unavailable.",
    "catalog_not_configured" => "The catalog is temporarily unavailable.",
    "invalid_input" => "That request could not be completed."
  }.freeze

  before_action :require_shopping_session!

  def create
    cart_service.add_item(
      shopping_session: @shopping_session,
      catalog_product_id: params[:catalog_product_id].to_s,
      catalog_variant_id: params[:catalog_variant_id].to_s,
      quantity: parsed_quantity,
      client_mutation_id: params[:client_mutation_id].to_s
    )
    redirect_to cart_path, notice: "Added to cart."
  rescue Cart::Error => error
    redirect_with_error(error)
  end

  def update
    item = current_cart_item!
    cart_service.change_quantity(
      shopping_session: @shopping_session, product_variant_id: item.product_variant_id,
      quantity: parsed_quantity, client_mutation_id: params[:client_mutation_id].to_s
    )
    redirect_to cart_path, notice: "Cart updated."
  rescue Cart::Error => error
    redirect_with_error(error)
  end

  def destroy
    item = current_cart_item!
    cart_service.remove_item(
      shopping_session: @shopping_session, product_variant_id: item.product_variant_id,
      client_mutation_id: params[:client_mutation_id].to_s
    )
    redirect_to cart_path, notice: "Item removed."
  rescue Cart::Error => error
    redirect_with_error(error)
  end

  private
    def require_shopping_session!
      @shopping_session = current_or_bootstrapped_shopping_session
      redirect_to cart_path, alert: "We couldn't start a shopping session. Please try again." unless @shopping_session
    end

    def current_cart_item!
      cart = cart_service.find_or_create_active_cart(shopping_session: @shopping_session)
      cart.cart_items.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      raise Cart::Error.new(:not_found)
    end

    def parsed_quantity
      Integer(params[:quantity], exception: false) || -1
    end

    def cart_service
      @cart_service ||= Cart::Service.new
    end

    def redirect_with_error(error)
      redirect_to cart_path, alert: ERROR_COPY.fetch(error.code.to_s, "That request could not be completed.")
    end
end
