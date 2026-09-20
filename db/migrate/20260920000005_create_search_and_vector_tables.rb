class CreateSearchAndVectorTables < ActiveRecord::Migration[8.1]
  def up
    create_search_documents
    create_embedding_models
    create_embeddings
  end

  def down
    drop_table :embeddings
    drop_table :embedding_models
    drop_table :search_documents
  end

  private

  def create_search_documents
    create_table :search_documents do |t|
      t.bigint :product_id
      t.bigint :product_variant_id
      t.text :document_kind, null: false
      t.text :locale, null: false, default: "en"
      t.text :normalized_text, null: false
      t.binary :content_hash, null: false
      t.text :source_version, null: false
      t.text :status, null: false
      t.datetime :generated_at, null: false
      t.timestamps null: false
    end

    execute <<~SQL
      ALTER TABLE search_documents
      ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (to_tsvector('english'::regconfig, normalized_text)) STORED
    SQL

    add_index :search_documents,
      %i[product_id product_variant_id document_kind locale source_version],
      unique: true,
      name: "index_search_documents_subject_kind_locale_version"
    add_index :search_documents, :product_variant_id
    add_index :search_documents,
      :search_vector,
      using: :gin,
      where: "status = 'active'",
      name: "index_search_documents_active_search_vector"
    add_foreign_key :search_documents, :products, on_delete: :cascade
    add_foreign_key :search_documents, :product_variants, on_delete: :cascade
    add_check_constraint :search_documents,
      "num_nonnulls(product_id,product_variant_id) = 1",
      name: "search_documents_subject_check"
    add_check_constraint :search_documents,
      "status IN ('active','superseded')",
      name: "search_documents_status_check"
    add_check_constraint :search_documents,
      "octet_length(content_hash) = 32",
      name: "search_documents_content_hash_check"
  end

  def create_embedding_models
    create_table :embedding_models do |t|
      t.text :provider, null: false
      t.text :key, null: false
      t.text :model_revision, null: false
      t.integer :dimensions, null: false
      t.text :distance_metric, null: false
      t.text :status, null: false, default: "active"
      t.binary :configuration_hash, null: false
      t.datetime :activated_at
      t.datetime :retired_at
      t.timestamps null: false
    end

    add_index :embedding_models,
      %i[provider key model_revision configuration_hash],
      unique: true,
      name: "index_embedding_models_identity"
    add_check_constraint :embedding_models, "dimensions > 0", name: "embedding_models_dimensions_check"
    add_check_constraint :embedding_models,
      "distance_metric IN ('cosine','l2','inner_product')",
      name: "embedding_models_distance_metric_check"
    add_check_constraint :embedding_models, "status IN ('active','retired')", name: "embedding_models_status_check"
    add_check_constraint :embedding_models,
      "octet_length(configuration_hash) = 32",
      name: "embedding_models_configuration_hash_check"
    add_check_constraint :embedding_models,
      "(status = 'retired') = (retired_at IS NOT NULL)",
      name: "embedding_models_retirement_state_check"
    add_check_constraint :embedding_models,
      "activated_at IS NULL OR retired_at IS NULL OR retired_at >= activated_at",
      name: "embedding_models_retirement_after_activation_check"
  end

  def create_embeddings
    create_table :embeddings do |t|
      t.bigint :search_document_id, null: false
      t.bigint :embedding_model_id, null: false
      t.column :value, "vector", null: false
      t.integer :dimensions, null: false
      t.binary :content_hash, null: false
      t.datetime :generated_at, null: false
      t.text :status, null: false, default: "active"
      t.text :error_code
      t.timestamps null: false
    end

    add_index :embeddings, :search_document_id
    add_index :embeddings, :embedding_model_id
    add_index :embeddings,
      %i[search_document_id embedding_model_id content_hash],
      unique: true,
      name: "index_embeddings_content_uniqueness"
    add_index :embeddings,
      %i[search_document_id embedding_model_id],
      unique: true,
      where: "status = 'active'",
      name: "index_embeddings_one_active_per_document_model"
    add_foreign_key :embeddings, :search_documents, on_delete: :cascade
    add_foreign_key :embeddings, :embedding_models, on_delete: :restrict
    add_check_constraint :embeddings,
      "dimensions > 0 AND vector_dims(value) = dimensions",
      name: "embeddings_dimension_check"
    add_check_constraint :embeddings,
      "status IN ('pending','active','superseded','failed')",
      name: "embeddings_status_check"
    add_check_constraint :embeddings,
      "(status = 'failed') = (error_code IS NOT NULL)",
      name: "embeddings_error_state_check"
    add_check_constraint :embeddings, "octet_length(content_hash) = 32", name: "embeddings_content_hash_check"
  end
end
