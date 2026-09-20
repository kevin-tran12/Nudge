module Agents
  module Tools
    # Structural allow-list projection from Catalog::ProductReader DTOs to the minimized
    # JSON shape returned to the voice provider. Only fields explicitly listed here are
    # ever emitted; anything not projected (sku, raw freshness timestamps, etc.) is dropped.
    module ProductProjection
      module_function

      def summary(product)
        variant = product.variants.first
        {
          "id" => product.id,
          "title" => product.title,
          "price" => price(variant&.price),
          "availability" => availability(variant&.availability)
        }
      end

      def detail(product)
        {
          "id" => product.id,
          "title" => product.title,
          "description" => product.description,
          "images" => product.images.map(&:url),
          "variants" => product.variants.map { |variant| variant_projection(variant) }
        }
      end

      def variant_projection(variant)
        {
          "id" => variant.id,
          "title" => variant.title,
          "price" => price(variant.price),
          "availability" => availability(variant.availability)
        }
      end

      def price(price)
        return { "state" => "unknown" } unless price && price.state == :known

        { "state" => "known", "amount_minor" => price.amount_minor, "currency" => price.currency }
      end

      def availability(availability)
        return { "state" => "unknown" } unless availability && availability.state != :unknown

        { "state" => availability.state.to_s, "quantity" => availability.quantity }
      end
    end
  end
end
