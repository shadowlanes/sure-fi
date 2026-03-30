require "test_helper"

class StatementImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:statement)
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "can be created without account" do
    import = StatementImport.create!(family: @family)
    assert import.persisted?
    assert_nil import.account
  end

  test "sets defaults after creation" do
    import = StatementImport.create!(family: @family, account: @account)
    import.reload

    assert_equal "inflows_positive", import.signage_convention
    assert_equal "%Y-%m-%d", import.date_format
    assert_equal "signed_amount", import.amount_type_strategy
  end

  test "uploaded? returns false without attached file" do
    refute @import.uploaded?
  end

  test "uploaded? returns true with attached file" do
    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    assert @import.uploaded?
  end

  test "configured? requires upload and rows" do
    refute @import.configured?

    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    refute @import.configured?

    @import.update_column(:rows_count, 5)
    assert @import.configured?
  end

  test "valid without account even when source file is attached" do
    import = StatementImport.create!(family: @family)
    import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    assert import.valid?
  end

  test "account_confirmed? requires both configured and account" do
    refute @import.account_confirmed?

    @import.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "s.pdf", content_type: "application/pdf")
    @import.update_column(:rows_count, 5)
    refute @import.account_confirmed?

    @import.update!(account: @account)
    assert @import.account_confirmed?
  end

  test "publishable? requires account_confirmed?" do
    @import.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "s.pdf", content_type: "application/pdf")
    @import.generate_rows_from_pdf([{ date: "2025-01-01", amount: "-10", currency: "USD", name: "Test", category: "", notes: "" }])
    @import.sync_mappings

    refute @import.publishable?, "Should not be publishable without account"

    @import.update!(account: @account)
    assert @import.publishable?, "Should be publishable with account"
  end

  test "detected_account_display_name combines detected fields" do
    @import.update!(detected_account_name: "Emirates NBD", detected_account_number: "4001", detected_currency: "USD", detected_account_type: "checking")
    assert_equal "Emirates NBD - ending 4001 - USD - Checking", @import.detected_account_display_name
  end

  test "detected_accountable_type maps credit_card correctly" do
    @import.update!(detected_account_type: "credit_card")
    assert_equal "CreditCard", @import.detected_accountable_type
  end

  test "detected_accountable_type defaults to Depository" do
    @import.update!(detected_account_type: "checking")
    assert_equal "Depository", @import.detected_accountable_type

    @import.update!(detected_account_type: nil)
    assert_equal "Depository", @import.detected_accountable_type
  end

  test "statement_import? returns true" do
    assert @import.statement_import?
  end

  test "required_column_keys returns date and amount" do
    assert_equal %i[date amount], @import.required_column_keys
  end

  test "column_keys includes currency" do
    assert_includes @import.column_keys, :currency
    assert_includes @import.column_keys, :date
    assert_includes @import.column_keys, :amount
    assert_includes @import.column_keys, :name
  end

  test "mapping_steps returns category and tag mappings" do
    assert_equal [ Import::CategoryMapping, Import::TagMapping ], @import.mapping_steps
  end

  test "generate_rows_from_pdf creates rows from extracted transactions" do
    transactions = [
      { date: "2024-01-15", amount: "-45.99", currency: "USD", name: "Grocery Store", category: "Groceries", notes: "" },
      { date: "2024-01-16", amount: "1500.00", currency: "USD", name: "Salary", category: "Income", notes: "Monthly" },
      { date: "2024-01-17", amount: "-12.50", currency: "EUR", name: "Coffee Shop", category: "", notes: "" }
    ]

    @import.generate_rows_from_pdf(transactions)
    @import.reload

    assert_equal 3, @import.rows_count
    assert_equal 3, @import.rows.count

    row1 = @import.rows.find_by(name: "Grocery Store")
    assert_equal "2024-01-15", row1.date
    assert_equal "-45.99", row1.amount
    assert_equal "USD", row1.currency
    assert_equal "Groceries", row1.category

    row3 = @import.rows.find_by(name: "Coffee Shop")
    assert_equal "EUR", row3.currency
  end

  test "generate_rows_from_pdf uses account currency as fallback" do
    @import.update!(account: @account)
    @account.update!(currency: "AED")

    transactions = [
      { date: "2024-01-15", amount: "-45.99", currency: "", name: "Test", category: "", notes: "" }
    ]

    @import.generate_rows_from_pdf(transactions)
    row = @import.rows.find_by(name: "Test")

    assert_equal "AED", row.currency
  end

  test "generate_rows_from_pdf uses family currency as last fallback" do
    @family.update!(currency: "GBP")
    import = StatementImport.create!(family: @family)

    transactions = [
      { date: "2024-01-15", amount: "-45.99", currency: "", name: "Test", category: "", notes: "" }
    ]

    import.generate_rows_from_pdf(transactions)
    row = import.rows.find_by(name: "Test")

    assert_equal "GBP", row.currency
  end

  test "generate_rows_from_pdf handles empty transaction list" do
    @import.generate_rows_from_pdf([])
    assert_equal 0, @import.rows_count
  end

  test "generate_rows_from_pdf defaults name to Imported item" do
    transactions = [
      { date: "2024-01-15", amount: "-10.00", currency: "USD", name: "", category: "", notes: "" }
    ]

    @import.generate_rows_from_pdf(transactions)
    row = @import.rows.find_by(amount: "-10.00")
    assert_equal "Imported item", row.name
  end

  test "parse_later enqueues StatementParseJob" do
    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )

    assert_enqueued_with(job: StatementParseJob, args: [@import]) do
      @import.parse_later
    end

    assert_equal "extracting", @import.reload.pdf_status
  end

  test "retry_extraction resets state and re-enqueues job" do
    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    @import.update!(pdf_status: "extraction_failed", pdf_error: "some error")

    assert_enqueued_with(job: StatementParseJob, args: [@import]) do
      @import.retry_extraction
    end

    @import.reload
    assert_equal "extracting", @import.pdf_status
    assert_nil @import.pdf_error
  end

  test "retry_extraction stores password when provided" do
    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    @import.update!(pdf_status: "extraction_failed", pdf_error: "This PDF is password-protected")

    assert_enqueued_with(job: StatementParseJob, args: [@import]) do
      @import.retry_extraction(password: "secret123")
    end

    assert_equal "secret123", @import.reload.pdf_password
  end

  test "password_required? returns true when error mentions password" do
    @import.update!(pdf_status: "extraction_failed", pdf_error: "This PDF is password-protected. Please provide the password.")
    assert @import.password_required?
  end

  test "password_required? returns false for other errors" do
    @import.update!(pdf_status: "extraction_failed", pdf_error: "Could not extract text from PDF.")
    refute @import.password_required?
  end

  test "password_required? returns false when not failed" do
    @import.update!(pdf_status: "extracted")
    refute @import.password_required?
  end

  test "clear_pdf_password! removes stored password" do
    @import.update!(pdf_password: "secret123")
    @import.clear_pdf_password!
    assert_nil @import.reload.pdf_password
  end

  test "clear_pdf_password! does nothing when no password" do
    @import.clear_pdf_password!
    assert_nil @import.reload.pdf_password
  end

  test "skips CSV-specific validations" do
    import = StatementImport.new(
      family: @family,
      col_sep: nil,
      number_format: nil,
      rows_to_skip: nil
    )

    assert import.valid?
  end

  test "import! creates transactions from rows" do
    @import.update!(account: @account)
    @import.generate_rows_from_pdf([
      { date: "2025-12-25", amount: "-99.77", currency: "USD", name: "Unique Statement Test Purchase", category: "", notes: "statement test" }
    ])
    @import.sync_mappings

    row = @import.rows.reload.first
    # Verify row data is correct before import
    assert_not_nil row, "No rows found after generate_rows_from_pdf. rows_count: #{@import.rows_count}"
    assert_equal "2025-12-25", row.date
    assert_equal "-99.77", row.amount
    assert_equal "2025-12-25", row.date_iso
    assert_equal BigDecimal("99.77"), row.signed_amount # inflows_positive convention: negative input becomes positive (expense)

    @import.send(:import!)

    entry = Entry.find_by(name: "Unique Statement Test Purchase")
    assert_not_nil entry, "Entry not found. Import error: #{@import.error}"
    assert_equal Date.new(2025, 12, 25), entry.date
    assert_equal "statement test", entry.notes
  end
end
