class StatementImport < Import
  MAX_PDF_SIZE = 20.megabytes
  ALLOWED_PDF_TYPES = %w[application/pdf].freeze

  after_create :set_defaults

  validate :account_required_for_import

  def uploaded?
    source_file.attached?
  end

  def configured?
    uploaded? && rows_count > 0
  end

  def account_confirmed?
    configured? && account.present?
  end

  def detected_account_display_name
    parts = [ detected_account_name ]
    parts << "ending #{detected_account_number}" if detected_account_number.present?
    parts << detected_currency if detected_currency.present?
    parts << detected_account_type&.titleize if detected_account_type.present?
    parts.compact.join(" - ")
  end

  def detected_accountable_type
    case detected_account_type&.downcase
    when "credit_card" then "CreditCard"
    when "savings" then "Depository"
    when "checking" then "Depository"
    else "Depository"
    end
  end

  def find_matching_accounts
    return family.accounts.none unless detected_account_number.present? || detected_account_name.present?

    scope = family.accounts.visible
    if detected_account_number.present?
      # Match on account name containing the account number
      scope.where("name ILIKE ?", "%#{detected_account_number}%")
    else
      scope.where("name ILIKE ?", "%#{detected_account_name}%")
    end
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

  def retry_extraction(password: nil)
    update!(pdf_status: nil, pdf_error: nil, pdf_text: nil, pdf_password: password)
    rows.destroy_all
    update_column(:rows_count, 0)
    parse_later
  end

  def password_required?
    pdf_status == "extraction_failed" && pdf_error&.include?("password")
  end

  def clear_pdf_password!
    update_column(:pdf_password, nil) if pdf_password.present?
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name currency category tags notes]
  end

  def publishable?
    account_confirmed? && super
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
    def account_required_for_import
      if rows_count > 0 && account.nil? && status == "importing"
        errors.add(:account, "must be selected before importing")
      end
    end

    def set_defaults
      self.signage_convention = "inflows_positive"
      self.date_format = "%Y-%m-%d"
      self.amount_type_strategy = "signed_amount"
      save!
    end
end
