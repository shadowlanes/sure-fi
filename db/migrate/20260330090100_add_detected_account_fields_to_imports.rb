class AddDetectedAccountFieldsToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :detected_account_name, :string
    add_column :imports, :detected_account_number, :string
    add_column :imports, :detected_account_type, :string
    add_column :imports, :detected_currency, :string
  end
end
