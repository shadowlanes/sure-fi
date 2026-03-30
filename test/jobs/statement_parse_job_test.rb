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

    provider = mock("provider")
    provider.expects(:parse_statement).returns(success_response(mock_transactions))
    Provider::Registry.expects(:get_provider).with(:openai).returns(provider)

    StatementParseJob.perform_now(@import)

    @import.reload
    assert_equal "extracted", @import.pdf_status
    assert_nil @import.pdf_password
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

    def success_response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def error_response(message)
      Provider::Response.new(success?: false, data: nil, error: message)
    end
end
