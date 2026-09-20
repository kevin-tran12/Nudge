class CreateCatalogCoreTables < ActiveRecord::Migration[8.1]
  def change
    create_suppliers
    create_categories
    create_products
    create_product_categories
    add_primary_category_membership_constraint
    create_product_variants
    create_supplier_products
    create_supplier_variants
    create_supplier_warehouses
  end

  private

  def create_suppliers
    create_table :suppliers do |t|
      t.text :key, null: false
      t.text :display_name, null: false
      t.text :adapter_version, null: false
      t.text :api_version, null: false
      t.text :status, null: false, default: "active"
      t.timestamps null: false
    end

    add_index :suppliers, :key, unique: true
    add_check_constraint :suppliers, "status IN ('active','disabled')", name: "suppliers_status_check"
  end

  def create_categories
    create_table :categories do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.text :key, null: false
      t.text :name, null: false
      t.bigint :parent_id
      t.text :status, null: false, default: "active"
      t.integer :position, null: false, default: 0
      t.integer :profile_version, null: false
      t.timestamps null: false
    end

    add_index :categories, :public_id, unique: true
    add_index :categories, :key, unique: true
    add_index :categories, :parent_id
    add_foreign_key :categories, :categories, column: :parent_id, on_delete: :restrict
    add_check_constraint :categories, "parent_id IS NULL OR parent_id <> id", name: "categories_not_self_parent_check"
    add_check_constraint :categories, "position >= 0", name: "categories_position_check"
    add_check_constraint :categories, "profile_version >= 0", name: "categories_profile_version_check"
  end

  def create_products
    create_table :products do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.text :status, null: false, default: "draft"
      t.text :title, null: false
      t.text :description, null: false, default: ""
      t.text :product_type
      t.text :brand
      t.bigint :primary_category_id
      t.datetime :published_at
      t.datetime :retired_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps null: false
    end

    add_index :products, :public_id, unique: true
    add_index :products, :status
    add_index :products, :primary_category_id
    add_foreign_key :products, :categories, column: :primary_category_id, on_delete: :restrict
    add_check_constraint :products,
      "status IN ('draft','active','unavailable','retired')",
      name: "products_status_check"
    add_check_constraint :products,
      "(status = 'retired') = (retired_at IS NOT NULL)",
      name: "products_retired_state_check"
    add_check_constraint :products,
      "published_at IS NULL OR retired_at IS NULL OR retired_at >= published_at",
      name: "products_retired_after_published_check"
    add_check_constraint :products, "lock_version >= 0", name: "products_lock_version_check"
  end

  def create_product_categories
    create_table :product_categories do |t|
      t.bigint :product_id, null: false
      t.bigint :category_id, null: false
      t.text :provenance, null: false
      t.timestamps null: false
    end

    add_index :product_categories, [ :product_id, :category_id ], unique: true
    add_index :product_categories, :category_id
    add_foreign_key :product_categories, :products, on_delete: :cascade
    add_foreign_key :product_categories, :categories, on_delete: :restrict
  end

  def add_primary_category_membership_constraint
    reversible do |direction|
      direction.up do
        execute <<~SQL
          ALTER TABLE products
          ADD CONSTRAINT fk_products_primary_category_membership
          FOREIGN KEY (id, primary_category_id)
          REFERENCES product_categories (product_id, category_id)
          ON DELETE NO ACTION
          DEFERRABLE INITIALLY DEFERRED
        SQL
      end
      direction.down do
        execute <<~SQL
          ALTER TABLE products
          DROP CONSTRAINT fk_products_primary_category_membership
        SQL
      end
    end
  end

  def create_product_variants
    create_table :product_variants do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :product_id, null: false
      t.text :canonical_sku
      t.text :title, null: false
      t.jsonb :option_summary, null: false, default: {}
      t.integer :option_schema_version, limit: 2, null: false
      t.text :status, null: false, default: "active"
      t.decimal :weight_value, precision: 14, scale: 4
      t.text :weight_unit
      t.decimal :length_value, precision: 14, scale: 4
      t.decimal :width_value, precision: 14, scale: 4
      t.decimal :height_value, precision: 14, scale: 4
      t.text :dimension_unit
      t.integer :lock_version, null: false, default: 0
      t.timestamps null: false
    end

    add_index :product_variants, :public_id, unique: true
    add_index :product_variants, :product_id
    add_index :product_variants, :canonical_sku, unique: true, where: "canonical_sku IS NOT NULL"
    add_foreign_key :product_variants, :products, on_delete: :cascade
    add_check_constraint :product_variants,
      "jsonb_typeof(option_summary) = 'object'",
      name: "product_variants_option_object_check"
    add_check_constraint :product_variants, "option_schema_version > 0", name: "product_variants_option_version_check"
    add_check_constraint :product_variants,
      "status IN ('active','unavailable','retired')",
      name: "product_variants_status_check"
    add_measurement_constraints(:product_variants)
    add_check_constraint :product_variants, "lock_version >= 0", name: "product_variants_lock_version_check"
  end

  def create_supplier_products
    create_table :supplier_products do |t|
      t.bigint :supplier_id, null: false
      t.bigint :product_id, null: false
      t.text :external_product_id, null: false
      t.text :external_sku
      t.text :external_category_id
      t.text :status, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :last_synced_at
      t.text :adapter_version, null: false
      t.bigint :latest_observation_id
      t.timestamps null: false
    end

    add_index :supplier_products, [ :supplier_id, :external_product_id ], unique: true
    add_index :supplier_products, [ :supplier_id, :product_id ], unique: true
    add_index :supplier_products, [ :id, :supplier_id ], unique: true
    add_index :supplier_products, :product_id
    add_index :supplier_products, :latest_observation_id
    add_foreign_key :supplier_products, :suppliers, on_delete: :restrict
    add_foreign_key :supplier_products, :products, on_delete: :restrict
    add_check_constraint :supplier_products,
      "last_seen_at >= first_seen_at",
      name: "supplier_products_seen_time_check"
    add_check_constraint :supplier_products,
      "last_synced_at IS NULL OR last_synced_at >= last_seen_at",
      name: "supplier_products_sync_time_check"
  end

  def create_supplier_variants
    create_table :supplier_variants do |t|
      t.bigint :supplier_id, null: false
      t.bigint :product_variant_id, null: false
      t.bigint :supplier_product_id, null: false
      t.text :external_variant_id, null: false
      t.text :external_variant_sku
      t.text :barcode
      t.decimal :weight_value, precision: 14, scale: 4
      t.text :weight_unit
      t.decimal :length_value, precision: 14, scale: 4
      t.decimal :width_value, precision: 14, scale: 4
      t.decimal :height_value, precision: 14, scale: 4
      t.text :dimension_unit
      t.text :status, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :last_synced_at
      t.bigint :latest_observation_id
      t.timestamps null: false
    end

    add_index :supplier_variants, [ :supplier_id, :external_variant_id ], unique: true
    add_index :supplier_variants, [ :supplier_id, :product_variant_id ], unique: true
    add_index :supplier_variants, :product_variant_id
    add_index :supplier_variants, [ :supplier_product_id, :supplier_id ]
    add_index :supplier_variants, :latest_observation_id
    add_foreign_key :supplier_variants, :suppliers, on_delete: :restrict
    add_foreign_key :supplier_variants, :product_variants, on_delete: :restrict
    add_foreign_key :supplier_variants,
      :supplier_products,
      column: [ :supplier_product_id, :supplier_id ],
      primary_key: [ :id, :supplier_id ],
      on_delete: :restrict,
      name: "fk_supplier_variants_product_supplier"
    add_measurement_constraints(:supplier_variants)
    add_check_constraint :supplier_variants,
      "last_seen_at >= first_seen_at",
      name: "supplier_variants_seen_time_check"
    add_check_constraint :supplier_variants,
      "last_synced_at IS NULL OR last_synced_at >= last_seen_at",
      name: "supplier_variants_sync_time_check"
  end

  def create_supplier_warehouses
    create_table :supplier_warehouses do |t|
      t.bigint :supplier_id, null: false
      t.text :external_warehouse_id, null: false
      t.column :country_code, "character(2)"
      t.text :region_code
      t.text :name
      t.text :verification_state
      t.text :status, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps null: false
    end

    add_index :supplier_warehouses, [ :supplier_id, :external_warehouse_id ], unique: true
    add_foreign_key :supplier_warehouses, :suppliers, on_delete: :restrict
    add_check_constraint :supplier_warehouses,
      "country_code IS NULL OR country_code ~ '^[A-Z]{2}$'",
      name: "supplier_warehouses_country_code_check"
    add_check_constraint :supplier_warehouses,
      "last_seen_at >= first_seen_at",
      name: "supplier_warehouses_seen_time_check"
  end

  def add_measurement_constraints(table)
    add_check_constraint table,
      "(weight_value IS NULL OR weight_value >= 0) AND " \
        "(length_value IS NULL OR length_value >= 0) AND " \
        "(width_value IS NULL OR width_value >= 0) AND " \
        "(height_value IS NULL OR height_value >= 0)",
      name: "#{table}_measurements_nonnegative_check"
    add_check_constraint table,
      "(weight_value IS NULL) = (weight_unit IS NULL)",
      name: "#{table}_weight_unit_pair_check"
    add_check_constraint table,
      "(dimension_unit IS NULL) = " \
        "(length_value IS NULL AND width_value IS NULL AND height_value IS NULL)",
      name: "#{table}_dimension_unit_check"
  end
end
