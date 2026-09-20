module Agents
  module Tools
    # Adds a specific catalog variant the shopper asked for to their own cart.
    # Takes only what to add and how many -- product_id/variant_id (the same
    # supplier-facing catalog ids search_products/get_product_details already
    # return) and quantity. It never takes a session/user/cart identifier: the
    # controller resolves the caller's own shopping_session server-side from the
    # trusted cookie/grant context before this tool ever runs (see
    # Voice::ToolsController), and Cart::Service scopes every mutation to that
    # session's own cart. Adding to cart reserves no inventory.
    class AddToCart
      MAX_ID_BYTES = 200
      MAX_QUANTITY = 100

      def initialize(cart_service: Cart::Service.new, resolver: Cart::CatalogVariantResolver.new)
        @cart_service = cart_service
        @resolver = resolver
      end

      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)

        product_id, variant_id, quantity = validate!(arguments)
        # Resolve once up front purely to know which local variant to report back on;
        # Cart::Service performs its own independent, authoritative resolution/pricing.
        local_variant_id = @resolver.call(catalog_product_id: product_id, catalog_variant_id: variant_id)
          .product_variant.id

        snapshot = @cart_service.add_item(
          shopping_session: shopping_session,
          catalog_product_id: product_id,
          catalog_variant_id: variant_id,
          quantity: quantity,
          client_mutation_id: SecureRandom.uuid
        )
        line_item = snapshot.line_items.find { |item| item.product_variant_id == local_variant_id }

        {
          "added" => true,
          "quantity_in_cart" => line_item&.quantity,
          "cart_item_count" => snapshot.line_items.sum(&:quantity),
          "cart_total" => total_projection(snapshot.total)
        }
      rescue Cart::Error => error
        raise Error.new(cart_error_code(error.code))
      end

      private
        def cart_error_code(code)
          case code
          when :not_found then :not_found
          when :quantity_invalid, :invalid_input then :invalid_arguments
          else :unavailable
          end
        end

        def total_projection(total)
          return { "state" => "unknown" } unless total.state == :known

          { "state" => "known", "amount_minor" => total.amount_minor, "currency" => total.currency }
        end

        def validate!(arguments)
          raise Error.new(:invalid_arguments) unless arguments.is_a?(Hash)

          arguments = arguments.stringify_keys
          extra = arguments.keys - %w[product_id variant_id quantity]
          raise Error.new(:invalid_arguments) unless extra.empty?

          product_id = arguments["product_id"]
          variant_id = arguments["variant_id"]
          [ product_id, variant_id ].each do |id|
            unless id.is_a?(String) && id.valid_encoding? && id.bytesize.between?(1, MAX_ID_BYTES)
              raise Error.new(:invalid_arguments)
            end
          end

          quantity = arguments.fetch("quantity", 1)
          unless quantity.is_a?(Integer) && quantity.between?(1, MAX_QUANTITY)
            raise Error.new(:invalid_arguments)
          end

          [ product_id, variant_id, quantity ]
        end
    end
  end
end
