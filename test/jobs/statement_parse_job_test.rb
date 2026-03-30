require "test_helper"

class StatementParseJobTest < ActiveJob::TestCase
  setup do
    @import = imports(:statement)
    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test content"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
  end

  test "sets pdf_status to extracted on success" do
    mock_transactions = [
      { "date" => "2025-01-15", "amount" => "-45.99", "currency" => "USD", "name" => "Grocery Store", "category" => "Groceries", "notes" => "" }
    ]

    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extracted", @import.pdf_status
    assert_equal 1, @import.rows_count
  end

  test "sets pdf_status to extraction_failed on error" do
    provider = mock("provider")
    provider.expects(:parse_statement).raises(StandardError, "API call failed")
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_equal "API call failed", @import.pdf_error
  end

  test "sets extraction_failed when no transactions found" do
    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response([]))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "No transactions found"
  end

  test "sets extraction_failed when OpenAI not configured" do
    Provider::Registry.expects(:get_provider).with(:openai).returns(nil)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "OpenAI"
  end

  test "clears password after successful extraction" do
    @import.update!(pdf_password: "secret123")

    mock_transactions = [
      { "date" => "2025-01-15", "amount" => "-45.99", "currency" => "USD", "name" => "Grocery", "category" => "", "notes" => "" }
    ]

    # Stub decryption since our test PDF isn't actually encrypted
    StatementParseJob.any_instance.stubs(:decrypt_pdf).returns("%PDF-1.4 decrypted")

    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extracted", @import.pdf_status
    assert_nil @import.pdf_password
  end

  test "saves detected account metadata" do
    mock_transactions = [
      { "date" => "2025-01-15", "amount" => "-45.99", "currency" => "USD", "name" => "Grocery", "category" => "", "notes" => "" }
    ]
    mock_account = { bank_name: "Emirates NBD", account_number: "4001", account_type: "checking", currency: "USD" }

    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions, account: mock_account))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "Emirates NBD", @import.detected_account_name
    assert_equal "4001", @import.detected_account_number
    assert_equal "checking", @import.detected_account_type
    assert_equal "USD", @import.detected_currency
  end

  test "reports password error when decryption fails" do
    @import.update!(pdf_password: "wrong_password")

    StatementParseJob.any_instance.stubs(:decrypt_pdf).raises("This PDF is password-protected. Please provide the correct password.")

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "password"
  end

  test "sends PDF as base64 to provider" do
    provider = mock("provider")
    provider.expects(:parse_statement).with { |args|
      # Verify base64 is passed, not extracted text
      args[:pdf_base64].present? && Base64.strict_decode64(args[:pdf_base64]).include?("%PDF-1.4")
    }.returns(success_response([]))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)
  end

  test "handles provider error response" do
    provider = mock("provider")
    provider.expects(:parse_statement).returns(error_response("Rate limit exceeded"))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "Rate limit exceeded"
  end

  private

    def success_response(transactions, account: nil)
      account ||= { bank_name: "Test Bank", account_number: "1234", account_type: "checking", currency: "USD" }
      data = { account: account, transactions: transactions }
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def error_response(message)
      Provider::Response.new(success?: false, data: nil, error: message)
    end
end
