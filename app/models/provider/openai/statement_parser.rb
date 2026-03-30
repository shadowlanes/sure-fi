class Provider::Openai::StatementParser
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :pdf_base64, :custom_provider, :langfuse_trace, :family

  def initialize(client, model:, pdf_base64:, custom_provider: false, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @pdf_base64 = pdf_base64
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
  end

  # Returns { account: { ... }, transactions: [ ... ] }
  def parse_statement
    if custom_provider
      parse_with_vision_generic
    else
      parse_with_vision_native
    end
  end

  private

    def parse_with_vision_native(text)
      span = langfuse_trace&.span(name: "parse_statement_api_call", input: {
        model: model, pdf_size: pdf_base64.length
      })

      response = client.responses.create(parameters: {
        model: model,
        input: [
          {
            role: "user",
            content: [
              { type: "input_file", file_data: "data:application/pdf;base64,#{pdf_base64}" },
              { type: "input_text", text: "Extract all transactions from this bank statement." }
            ]
          }
        ],
        instructions: instructions,
        text: {
          format: {
            type: "json_schema",
            name: "parse_bank_statement_transactions",
            strict: true,
            schema: json_schema
          }
        }
      })

      result = extract_result_native(response)

      record_usage(
        model,
        response.dig("usage"),
        operation: "parse_statement",
        metadata: { pdf_size: pdf_base64.length, transaction_count: result[:transactions].size }
      )

      span&.end(output: { transaction_count: result[:transactions].size }, usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def parse_with_vision_generic
      span = langfuse_trace&.span(name: "parse_statement_api_call", input: {
        model: model, pdf_size: pdf_base64.length
      })

      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          {
            role: "user",
            content: [
              {
                type: "image_url",
                image_url: { url: "data:application/pdf;base64,#{pdf_base64}" }
              },
              {
                type: "text",
                text: "Extract all transactions from this bank statement."
              }
            ]
          }
        ],
        response_format: { type: "json_object" }
      }

      Rails.logger.info("StatementParser sending PDF (#{pdf_base64.length} base64 chars) to LLM model #{model}")

      response = client.chat(parameters: params)

      raw = response.dig("choices", 0, "message", "content")
      Rails.logger.info("StatementParser raw LLM response (first 2000 chars): #{raw.to_s[0..2000]}")
      parsed = parse_json_flexibly(raw)
      account_info = extract_account_info(parsed)
      transactions = normalize_transactions(parsed)
      Rails.logger.info("StatementParser extracted #{transactions.size} transactions, account: #{account_info.inspect}")

      record_usage(
        model,
        response.dig("usage"),
        operation: "parse_statement",
        metadata: { pdf_size: pdf_base64.length, transaction_count: transactions.size }
      )

      span&.end(output: { transaction_count: transactions.size }, usage: response.dig("usage"))
      { account: account_info, transactions: transactions }
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def instructions
      <<~INSTRUCTIONS.strip
        You are a financial document parser specializing in bank statements. Your job is to extract
        account information and every transaction from the provided bank statement PDF.

        Return a JSON object with two keys: "account" and "transactions".

        For "account", return:
        - bank_name: the name of the bank or financial institution (e.g., "Emirates NBD", "HDFC Bank", "Chase")
        - account_number: the last 4 digits of the account number, or the full account number if visible. Empty string if not found.
        - account_type: one of "checking", "savings", "credit_card", or "other"
        - currency: the primary ISO 4217 currency code for the account (e.g., "USD", "AED", "INR")

        For each transaction in "transactions", return:
        - date: in ISO 8601 format (YYYY-MM-DD)
        - amount: as a signed decimal number (positive for deposits/credits, negative for withdrawals/debits). No currency symbols.
        - currency: ISO 4217 currency code (e.g., "USD", "EUR", "GBP", "INR", "JPY").
          Extract from the transaction line, statement header, or account details.
          Return empty string only if truly indeterminate.
        - name: the transaction description or payee name
        - category: your best guess at a spending category (e.g., "Groceries", "Restaurants", "Salary", "Utilities", "Transfer"), or empty string if unclear
        - notes: reference numbers, check numbers, or other details. Empty string if none.

        Rules:
        - Extract EVERY transaction line from ALL pages. Do not skip any.
        - Do NOT include opening balances, closing balances, summary totals, or interest accrual summaries as transactions
          UNLESS they represent an actual charge or credit to the account.
        - Dates must be valid calendar dates within the statement period.
        - If the statement shows transactions in multiple currencies, use the correct currency for each.
        - If all transactions share one currency, use the currency from the statement header or account info.
        - The statement may be bilingual (e.g., English and Arabic). Extract data from whichever language has the transaction details.
        - Return valid JSON only. No explanations.
      INSTRUCTIONS
    end

    def json_schema
      {
        type: "object",
        properties: {
          account: {
            type: "object",
            properties: {
              bank_name: { type: "string", description: "Bank or institution name" },
              account_number: { type: "string", description: "Last 4 digits or full account number" },
              account_type: { type: "string", description: "checking, savings, credit_card, or other" },
              currency: { type: "string", description: "Primary ISO 4217 currency code" }
            },
            required: %w[bank_name account_number account_type currency],
            additionalProperties: false
          },
          transactions: {
            type: "array",
            items: {
              type: "object",
              properties: {
                date: { type: "string", description: "ISO 8601 date (YYYY-MM-DD)" },
                amount: { type: "string", description: "Signed decimal amount" },
                currency: { type: "string", description: "ISO 4217 currency code or empty string" },
                name: { type: "string", description: "Transaction description" },
                category: { type: "string", description: "Spending category or empty string" },
                notes: { type: "string", description: "Additional notes or empty string" }
              },
              required: %w[date amount currency name category notes],
              additionalProperties: false
            }
          }
        },
        required: %w[account transactions],
        additionalProperties: false
      }
    end

    def extract_result_native(response)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      parsed = JSON.parse(raw)
      { account: extract_account_info(parsed), transactions: normalize_transactions(parsed) }
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in statement parse response: #{e.message}"
    end

    def extract_account_info(parsed)
      acct = if parsed.is_a?(Hash)
        parsed["account"] || {}
      else
        {}
      end

      {
        bank_name: acct["bank_name"].to_s.strip.presence,
        account_number: acct["account_number"].to_s.strip.presence,
        account_type: acct["account_type"].to_s.strip.presence,
        currency: acct["currency"].to_s.strip.presence
      }
    end

    def normalize_transactions(parsed)
      txns = if parsed.is_a?(Array)
        parsed
      else
        parsed["transactions"] || parsed["results"] || []
      end

      txns.filter_map do |txn|
        date = txn["date"].to_s.strip
        amount = txn["amount"].to_s.strip
        name = txn["name"].to_s.strip

        next if date.blank? || amount.blank?

        {
          date: date,
          amount: amount,
          currency: txn["currency"].to_s.strip,
          name: name.presence || "Imported item",
          category: txn["category"].to_s.strip,
          notes: txn["notes"].to_s.strip
        }
      end
    end

    def parse_json_flexibly(raw)
      return {} if raw.blank?

      cleaned = raw.gsub(/<think>[\s\S]*?<\/think>/m, "").strip

      JSON.parse(cleaned)
    rescue JSON::ParserError
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        return JSON.parse($1)
      end

      if cleaned =~ /(\{[\s\S]*\})/m
        return JSON.parse($1)
      end

      raise Provider::Openai::Error, "Could not parse JSON from statement parse response"
    end
end
