require "test_helper"
require "pg"

class DatabaseSearchVectorsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLES = %w[search_documents embedding_models embeddings].freeze

  setup { reset_database_rows }
  teardown { reset_database_rows }

  test "installs the search and vector tables" do
    TABLES.each { |table| assert connection.data_source_exists?(table), table }
  end

  test "creates the exact DB-05 column dictionary" do
    expected = {
      "search_documents" => %w[id product_id product_variant_id document_kind locale normalized_text search_vector content_hash source_version status generated_at created_at updated_at],
      "embedding_models" => %w[id provider key model_revision dimensions distance_metric status configuration_hash activated_at retired_at created_at updated_at],
      "embeddings" => %w[id search_document_id embedding_model_id value dimensions content_hash generated_at status error_code created_at updated_at]
    }
    expected.each do |table, columns|
      assert_equal columns.sort, connection.columns(table).map(&:name).sort, table
    end
  end

  test "rejects a search document with both or neither subject present" do
    product_id = insert_product
    variant_id = insert_product_variant(product_id:)

    assert_database_error("search_documents_subject_check") do
      insert_search_document(product_id: nil, product_variant_id: nil)
    end
    assert_database_error("search_documents_subject_check") do
      insert_search_document(product_id:, product_variant_id: variant_id)
    end

    document_id = insert_search_document(product_id:, product_variant_id: nil)
    assert connection.select_value("SELECT 1 FROM search_documents WHERE id = #{document_id}")
  end

  test "populates and updates the STORED generated search vector and serves it through the GIN index" do
    product_id = insert_product
    document_id = insert_search_document(product_id:, normalized_text: "insulated stainless steel travel mug")

    vector = connection.select_value("SELECT search_vector::text FROM search_documents WHERE id = #{document_id}")
    assert_includes vector, "mug"
    assert_includes vector, "insul"

    matches = connection.select_value(<<~SQL)
      SELECT count(*) FROM search_documents
      WHERE id = #{document_id} AND search_vector @@ plainto_tsquery('english', 'travel mug')
    SQL
    assert_equal 1, matches.to_i

    connection.execute("UPDATE search_documents SET normalized_text = 'ceramic espresso cup' WHERE id = #{document_id}")
    updated_vector = connection.select_value("SELECT search_vector::text FROM search_documents WHERE id = #{document_id}")
    refute_includes updated_vector, "mug"
    assert_includes updated_vector, "espresso"

    no_longer_matches = connection.select_value(<<~SQL)
      SELECT count(*) FROM search_documents
      WHERE id = #{document_id} AND search_vector @@ plainto_tsquery('english', 'travel mug')
    SQL
    assert_equal 0, no_longer_matches.to_i

    assert_database_error do
      connection.execute("UPDATE search_documents SET search_vector = to_tsvector('simple', 'hack') WHERE id = #{document_id}")
    end

    plan = connection.select_values(<<~SQL).join(" ")
      EXPLAIN SELECT id FROM search_documents
      WHERE search_vector @@ plainto_tsquery('english', 'espresso') AND status = 'active'
    SQL
    assert_includes plan, "Bitmap Index Scan"
    assert_includes plan, "index_search_documents_active_search_vector"
  end

  test "enforces embedding model and content uniqueness including the partial one-active rule" do
    model_id = insert_embedding_model
    document_id = insert_search_document(product_id: insert_product)

    embedding_id = insert_embedding(document_id:, model_id:, content_hash: digest("a"))
    assert connection.select_value("SELECT 1 FROM embeddings WHERE id = #{embedding_id}")

    assert_database_error do
      insert_embedding(document_id:, model_id:, content_hash: digest("a"))
    end

    assert_database_error do
      insert_embedding(document_id:, model_id:, content_hash: digest("b"), status: "active")
    end

    connection.execute("UPDATE embeddings SET status = 'superseded' WHERE id = #{embedding_id}")
    superseding_id = insert_embedding(document_id:, model_id:, content_hash: digest("b"), status: "active")
    assert connection.select_value("SELECT 1 FROM embeddings WHERE id = #{superseding_id}")
  end

  test "rejects a mismatched vector dimension and nonpositive dimensions" do
    model_id = insert_embedding_model(dimensions: 3)
    document_id = insert_search_document(product_id: insert_product)

    assert_database_error("embeddings_dimension_check") do
      insert_embedding(document_id:, model_id:, dimensions: 3, vector_literal: "[1,2]")
    end
    assert_database_error("embeddings_dimension_check") do
      insert_embedding(document_id:, model_id:, dimensions: 0, vector_literal: "[1,2,3]")
    end
    assert_database_error("embeddings_dimension_check") do
      insert_embedding(document_id:, model_id:, dimensions: -1, vector_literal: "[1,2,3]")
    end

    embedding_id = insert_embedding(document_id:, model_id:, dimensions: 3, vector_literal: "[1,2,3]")
    assert connection.select_value("SELECT 1 FROM embeddings WHERE id = #{embedding_id}")
  end

  test "performs exact nearest-neighbor search without an approximate index" do
    model_id = insert_embedding_model(dimensions: 3)
    near_document_id = insert_search_document(product_id: insert_product, normalized_text: "near")
    far_document_id = insert_search_document(product_id: insert_product, normalized_text: "far")
    insert_embedding(document_id: near_document_id, model_id:, dimensions: 3, vector_literal: "[1,1,1]", content_hash: digest("near"))
    insert_embedding(document_id: far_document_id, model_id:, dimensions: 3, vector_literal: "[10,10,10]", content_hash: digest("far"))

    ordered = connection.select_values(<<~SQL)
      SELECT search_document_id FROM embeddings
      WHERE embedding_model_id = #{model_id} AND status = 'active'
      ORDER BY value <-> '[1,1,1]'::vector
    SQL
    assert_equal [ near_document_id, far_document_id ], ordered.map(&:to_i)

    refute connection.indexes("embeddings").any? { |index| index.using.to_s.match?(/hnsw|ivfflat/i) }

    plan = connection.select_values(<<~SQL).join(" ")
      EXPLAIN SELECT search_document_id FROM embeddings
      WHERE embedding_model_id = #{model_id}
      ORDER BY value <-> '[1,1,1]'::vector
    SQL
    refute_includes plan.downcase, "index scan using"
  end

  test "constrains the embedding model distance metric vocabulary" do
    assert_database_error("embedding_models_distance_metric_check") do
      insert_embedding_model(distance_metric: "manhattan")
    end
    %w[cosine l2 inner_product].each_with_index do |metric, index|
      id = insert_embedding_model(distance_metric: metric, key: "model-#{index}")
      assert connection.select_value("SELECT 1 FROM embedding_models WHERE id = #{id}")
    end
  end

  test "rejects hash columns with the wrong byte length" do
    assert_database_error("search_documents_content_hash_check") do
      insert_search_document(product_id: insert_product, content_hash_hex: "ab" * 31)
    end
    assert_database_error("embedding_models_configuration_hash_check") do
      insert_embedding_model(configuration_hash_hex: "ab" * 20)
    end
    document_id = insert_search_document(product_id: insert_product)
    model_id = insert_embedding_model
    assert_database_error("embeddings_content_hash_check") do
      insert_embedding(document_id:, model_id:, content_hash_hex: "ab" * 16)
    end
  end

  test "cascades embedding deletion from the search document and restricts a referenced embedding model" do
    model_id = insert_embedding_model
    document_id = insert_search_document(product_id: insert_product)
    embedding_id = insert_embedding(document_id:, model_id:)

    assert_database_error do
      connection.execute("DELETE FROM embedding_models WHERE id = #{model_id}")
    end

    connection.execute("DELETE FROM search_documents WHERE id = #{document_id}")
    assert_nil connection.select_value("SELECT 1 FROM embeddings WHERE id = #{embedding_id}")
  end

  private

  def connection = ActiveRecord::Base.connection

  def reset_database_rows
    connection.execute("TRUNCATE #{(TABLES + %w[product_variants products]).join(', ')} RESTART IDENTITY CASCADE")
  end

  def assert_database_error(message = nil)
    error = assert_raises(ActiveRecord::StatementInvalid) { yield }
    assert_includes error.message, message if message
  end

  def digest(seed)
    Digest::SHA256.digest(seed)
  end

  def insert_product
    connection.select_value(<<~SQL).to_i
      INSERT INTO products (status,title,description,lock_version,created_at,updated_at)
      VALUES ('draft','Product','',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
  end

  def insert_product_variant(product_id:)
    connection.select_value(<<~SQL).to_i
      INSERT INTO product_variants
        (product_id,title,option_summary,option_schema_version,status,lock_version,created_at,updated_at)
      VALUES (#{product_id},'Variant','{}',1,'active',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
  end

  def insert_search_document(product_id: nil, product_variant_id: nil, document_kind: "listing", locale: "en",
    normalized_text: "sample normalized text", source_version: "v1", status: "active",
    content_hash_hex: nil)
    hash_sql = content_hash_hex ? "decode('#{content_hash_hex}','hex')" : "decode(repeat('ab',32),'hex')"
    connection.select_value(<<~SQL).to_i
      INSERT INTO search_documents
        (product_id,product_variant_id,document_kind,locale,normalized_text,content_hash,source_version,status,generated_at,created_at,updated_at)
      VALUES (
        #{product_id || "NULL"},#{product_variant_id || "NULL"},#{connection.quote(document_kind)},#{connection.quote(locale)},
        #{connection.quote(normalized_text)},#{hash_sql},#{connection.quote(source_version)},#{connection.quote(status)},
        CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
      ) RETURNING id
    SQL
  end

  def insert_embedding_model(provider: "openai", key: "text-embed", model_revision: "v1", dimensions: 3,
    distance_metric: "cosine", status: "active", configuration_hash_hex: nil)
    hash_sql = configuration_hash_hex ? "decode('#{configuration_hash_hex}','hex')" : "decode(repeat('cd',32),'hex')"
    connection.select_value(<<~SQL).to_i
      INSERT INTO embedding_models
        (provider,key,model_revision,dimensions,distance_metric,status,configuration_hash,created_at,updated_at)
      VALUES (
        #{connection.quote(provider)},#{connection.quote(key)},#{connection.quote(model_revision)},#{dimensions},
        #{connection.quote(distance_metric)},#{connection.quote(status)},#{hash_sql},CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
      ) RETURNING id
    SQL
  end

  def insert_embedding(document_id:, model_id:, dimensions: 3, vector_literal: "[1,2,3]", content_hash: nil,
    content_hash_hex: nil, status: "active")
    hash_sql =
      if content_hash_hex
        "decode('#{content_hash_hex}','hex')"
      elsif content_hash
        "decode('#{content_hash.unpack1('H*')}','hex')"
      else
        "decode(repeat('ef',32),'hex')"
      end
    connection.select_value(<<~SQL).to_i
      INSERT INTO embeddings
        (search_document_id,embedding_model_id,value,dimensions,content_hash,generated_at,status,created_at,updated_at)
      VALUES (
        #{document_id},#{model_id},'#{vector_literal}'::vector,#{dimensions},#{hash_sql},CURRENT_TIMESTAMP,
        #{connection.quote(status)},CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
      ) RETURNING id
    SQL
  end
end
