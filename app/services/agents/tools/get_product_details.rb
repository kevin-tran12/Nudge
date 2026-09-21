module Agents
  module Tools
    class GetProductDetails
      MAX_ID_BYTES = 200

      def initialize(product_reader: Catalog::ReaderSelection.call)
        @product_reader = product_reader
      end

      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)

        product_id = validate!(arguments)
        product = @product_reader.detail(id: product_id)
        { "found" => true, "product" => ProductProjection.detail(product) }
      rescue Catalog::ProductReader::Error => error
        raise Error.new(error.code == :not_found || error.code == :invalid_input ? :not_found : :unavailable)
      end

      private
        def validate!(arguments)
          raise Error.new(:invalid_arguments) unless arguments.is_a?(Hash)

          arguments = arguments.stringify_keys
          extra = arguments.keys - %w[product_id]
          raise Error.new(:invalid_arguments) unless extra.empty?

          product_id = arguments["product_id"]
          unless product_id.is_a?(String) && product_id.valid_encoding? && product_id.bytesize.between?(1, MAX_ID_BYTES)
            raise Error.new(:invalid_arguments)
          end

          product_id
        end
    end
  end
end
