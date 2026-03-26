class AddPdfPasswordToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :pdf_password, :string
  end
end
