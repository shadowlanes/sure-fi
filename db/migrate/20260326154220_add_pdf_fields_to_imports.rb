class AddPdfFieldsToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :pdf_status, :string
    add_column :imports, :pdf_error, :text
    add_column :imports, :pdf_text, :text
  end
end
