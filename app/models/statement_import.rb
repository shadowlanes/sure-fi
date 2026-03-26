class StatementImport < Import
  MAX_PDF_SIZE = 20.megabytes
  ALLOWED_PDF_TYPES = %w[application/pdf].freeze

  after_create :set_defaults

  validates :account, presence: true

  def uploaded?
    source_file.attached?
  end

  def configured?
    uploaded? && rows_count > 0
  end

  def extract_pdf_text
    tempfile = source_file.blob.open
    reader = PDF::Reader.new(tempfile)

    text = reader.pages.map(&:text).join("\n--- PAGE BREAK ---\n")
    tempfile.close

    raise "Could not extract text from PDF. The file may be scanned or image-based." if text.strip.blank?

    text
  end

  def generate_rows_from_pdf(extracted_transactions)
    rows.destroy_all

    mapped_rows = extracted_transactions.map do |txn|
      {
        date: txn[:date].to_s,
        amount: txn[:amount].to_s,
        currency: (txn[:currency].presence || account&.currency || family.currency).to_s,
        name: (txn[:name].presence || "Imported item").to_s,
        category: txn[:category].to_s,
        tags: "",
        account: "",
        notes: txn[:notes].to_s
      }
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
    update_column(:rows_count, rows.count)
  end

  def parse_later
    update!(pdf_status: "extracting")
    StatementParseJob.perform_later(self)
  end

  def retry_extraction
    update!(pdf_status: nil, pdf_error: nil, pdf_text: nil)
    rows.destroy_all
    update_column(:rows_count, 0)
    parse_later
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name currency category tags notes]
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping ]
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new

      rows.each_with_index do |row, index|
        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        effective_currency = row.currency.presence || account.currency.presence || family.currency

        adapter = Account::ProviderImportAdapter.new(account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: effective_currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.transaction.tags = tags if tags.any?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import = self
          updated_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        else
          new_transactions << Transaction.new(
            category: category,
            tags: tags,
            entry: Entry.new(
              account: account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self
            )
          )
        end
      end

      updated_entries.each do |entry|
        entry.transaction.save!
        entry.save!
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  private
    def set_defaults
      self.signage_convention = "inflows_positive"
      self.date_format = "%Y-%m-%d"
      self.amount_type_strategy = "signed_amount"
      save!
    end
end
