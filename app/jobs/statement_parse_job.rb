class StatementParseJob < ApplicationJob
  queue_as :high_priority

  def perform(import)
    pdf_base64 = read_pdf_as_base64(import)

    provider = Provider::Registry.get_provider(:openai)
    raise "OpenAI provider is not configured. Please set OPENAI_ACCESS_TOKEN." unless provider

    response = provider.parse_statement(pdf_base64: pdf_base64, family: import.family)
    raise response.error if response.error.present?

    transactions = response.data

    if transactions.empty?
      import.update!(pdf_status: "extraction_failed", pdf_error: "No transactions found in the statement.")
      return
    end

    import.generate_rows_from_pdf(transactions)
    import.sync_mappings
    import.update!(pdf_status: "extracted")

    import.clear_pdf_password!
  rescue => e
    Rails.logger.error("StatementParseJob failed for import #{import.id}: #{e.message}")
    import.update!(pdf_status: "extraction_failed", pdf_error: e.message)
  end

  private

    def read_pdf_as_base64(import)
      import.source_file.blob.open do |tempfile|
        Base64.strict_encode64(tempfile.read)
      end
    end
end
