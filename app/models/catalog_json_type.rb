class CatalogJsonType < ActiveRecord::Type::Json
  def deserialize(value)
    return value unless value.is_a?(String)
    return if value.empty?

    JSON.parse(value)
  end
end
