require "test_helper"

class StatementImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "creates statement import without account" do
    assert_difference "Import.count", 1 do
      post imports_url, params: {
        import: { type: "StatementImport" }
      }
    end

    import = Import.all.ordered.first
    assert_instance_of StatementImport, import
    assert_redirected_to import_upload_url(import)
  end

  # TODO: Add test with actual PDF file upload + parse job enqueue
  # TODO: Add test that rejects non-PDF files
  # Requires a valid PDF fixture file (to be provided later)

  test "shows upload page for statement import" do
    import = imports(:statement)

    get import_upload_url(import)
    assert_response :success
  end

  test "shows processing state when extracting" do
    import = imports(:statement)
    import.update!(pdf_status: "extracting")

    get import_upload_url(import)
    assert_response :success
  end

  test "redirects to account review when extraction complete and no account" do
    import = imports(:statement)
    import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    import.update!(pdf_status: "extracted", account: nil)
    import.update_column(:rows_count, 1)

    get import_upload_url(import)
    assert_redirected_to import_account_review_url(import)
  end

  test "redirects to clean when extraction complete and account set" do
    import = imports(:statement)
    import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    import.update!(pdf_status: "extracted", account: @account)
    import.update_column(:rows_count, 1)

    get import_upload_url(import)
    assert_redirected_to import_clean_url(import)
  end

  test "shows error state when extraction failed" do
    import = imports(:statement)
    import.update!(pdf_status: "extraction_failed", pdf_error: "Could not parse PDF")

    get import_upload_url(import)
    assert_response :success
  end

  # TODO: Add test for PDF upload via update action (requires valid PDF fixture)

  test "retry extraction via update" do
    import = imports(:statement)
    import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    import.update!(pdf_status: "extraction_failed", pdf_error: "some error")

    assert_enqueued_with(job: StatementParseJob) do
      patch import_upload_url(import), params: {
        import: { retry: "true" }
      }
    end

    assert_equal "extracting", import.reload.pdf_status
    assert_redirected_to import_upload_url(import)
  end

  test "retry extraction with password" do
    import = imports(:statement)
    import.source_file.attach(
      io: StringIO.new("%PDF-1.4 test"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )
    import.update!(pdf_status: "extraction_failed", pdf_error: "This PDF is password-protected. Please provide the password.")

    assert_enqueued_with(job: StatementParseJob) do
      patch import_upload_url(import), params: {
        import: { retry: "true", pdf_password: "mysecret" }
      }
    end

    import.reload
    assert_equal "extracting", import.pdf_status
    assert_equal "mysecret", import.pdf_password
    assert_redirected_to import_upload_url(import)
  end

  test "shows password field when error is password-related" do
    import = imports(:statement)
    import.update!(pdf_status: "extraction_failed", pdf_error: "This PDF is password-protected. Please provide the password.")

    get import_upload_url(import)
    assert_response :success
  end

  test "shows account review page" do
    import = imports(:statement)
    import.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "s.pdf", content_type: "application/pdf")
    import.update!(pdf_status: "extracted", detected_account_name: "Emirates NBD", detected_account_type: "checking", detected_currency: "USD")
    import.update_column(:rows_count, 5)

    get import_account_review_url(import)
    assert_response :success
  end

  test "account review assigns existing account" do
    import = imports(:statement)
    import.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "s.pdf", content_type: "application/pdf")
    import.update!(pdf_status: "extracted")
    import.update_column(:rows_count, 5)

    patch import_account_review_url(import), params: {
      import: { account_action: "existing", account_id: @account.id }
    }

    assert_equal @account, import.reload.account
    assert_redirected_to import_clean_url(import)
  end

  test "account review creates new account" do
    import = imports(:statement)
    import.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "s.pdf", content_type: "application/pdf")
    import.update!(pdf_status: "extracted", detected_account_name: "HDFC Bank", detected_account_type: "checking", detected_currency: "INR")
    import.update_column(:rows_count, 5)

    assert_difference "Account.count", 1 do
      patch import_account_review_url(import), params: {
        import: { account_action: "create" }
      }
    end

    import.reload
    assert_not_nil import.account
    assert_equal "INR", import.account.currency
    assert_redirected_to import_clean_url(import)
  end

  test "show redirects to account review when no account set" do
    import = imports(:statement)
    import.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "s.pdf", content_type: "application/pdf")
    import.update!(pdf_status: "extracted", account: nil)
    import.update_column(:rows_count, 5)

    get import_url(import)
    assert_redirected_to import_account_review_url(import)
  end

  test "configuration page redirects to clean for statement import" do
    import = imports(:statement)

    get import_configuration_url(import)
    assert_redirected_to import_clean_url(import)
  end

  test "show redirects to upload when extracting" do
    import = imports(:statement)
    import.update!(pdf_status: "extracting")

    get import_url(import)
    assert_redirected_to import_upload_url(import)
  end

  test "destroys statement import" do
    import = imports(:statement)

    assert_difference "Import.count", -1 do
      delete import_url(import)
    end

    assert_redirected_to imports_path
  end
end
