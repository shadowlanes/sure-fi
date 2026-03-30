require "test_helper"

class StatementParseJobTest < ActiveJob::TestCase
  setup do
    @import = imports(:statement)
    @import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
  end

  test "sets pdf_status to extracted on success" do
    mock_transactions = [
      { "date" => "2025-01-15", "amount" => "-45.99", "currency" => "USD", "name" => "Grocery Store", "category" => "Groceries", "notes" => "" }
    ]

    @import.expects(:extract_pdf_text).returns("Sample bank statement text")
    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extracted", @import.pdf_status
    assert_equal 1, @import.rows_count
  end

  test "sets pdf_status to extraction_failed on error" do
    @import.expects(:extract_pdf_text).raises(StandardError, "PDF text extraction failed")

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_equal "PDF text extraction failed", @import.pdf_error
  end

  test "sets extraction_failed when no transactions found" do
    @import.expects(:extract_pdf_text).returns("Some text with no transactions")
    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response([]))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "No transactions found"
  end

  test "sets extraction_failed when OpenAI not configured" do
    @import.expects(:extract_pdf_text).returns("Sample text")
    Provider::Registry.expects(:get_provider).with(:openai).returns(nil)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "OpenAI"
  end

  test "handles encrypted PDF with specific error message" do
    @import.expects(:extract_pdf_text).raises(PDF::Reader::EncryptedPDFError)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "password-protected"
  end

  test "clears password after successful extraction" do
    @import.update!(pdf_password: "secret123")

    mock_transactions = [
      { "date" => "2025-01-15", "amount" => "-45.99", "currency" => "USD", "name" => "Grocery", "category" => "", "notes" => "" }
    ]

    @import.expects(:extract_pdf_text).returns("Sample text")
    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extracted", @import.pdf_status
    assert_nil @import.pdf_password
  end

  test "stores pdf_text for debugging" do
    pdf_text = "Bank Statement\nDate Amount Description\n2025-01-15 -45.99 Grocery"

    mock_transactions = [
      { "date" => "2025-01-15", "amount" => "-45.99", "currency" => "USD", "name" => "Grocery", "category" => "", "notes" => "" }
    ]

    @import.expects(:extract_pdf_text).returns(pdf_text)
    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    assert_equal pdf_text, @import.reload.pdf_text
  end

  test "handles provider error response" do
    @import.expects(:extract_pdf_text).returns("Sample text")
    provider = mock("provider")
    provider.expects(:parse_statement).returns(error_response("Rate limit exceeded"))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extraction_failed", @import.pdf_status
    assert_includes @import.pdf_error, "Rate limit exceeded"
  end

  private

    def success_response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def error_response(message)
      Provider::Response.new(success?: false, data: nil, error: message)
    end
end
