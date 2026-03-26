class Import::UploadsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    if @import.is_a?(StatementImport) && @import.pdf_status == "extracted"
      redirect_to import_clean_path(@import)
    end
  end

  def sample_csv
    send_data @import.csv_template.to_csv,
      filename: "#{@import.type.underscore.split('_').first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  end

  def update
    if @import.is_a?(StatementImport)
      handle_statement_upload
    elsif csv_valid?(csv_str)
      @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
      @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
      @import.save!(validate: false)

      redirect_to import_configuration_path(@import, template_hint: true), notice: "CSV uploaded successfully."
    else
      flash.now[:alert] = "Must be valid CSV with headers and at least one row of data"

      render :show, status: :unprocessable_entity
    end
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def csv_str
      @csv_str ||= upload_params[:csv_file]&.read || upload_params[:raw_file_str]
    end

    def csv_valid?(str)
      begin
        csv = Import.parse_csv_str(str, col_sep: upload_params[:col_sep])
        return false if csv.headers.empty?
        return false if csv.count == 0
        true
      rescue CSV::MalformedCSVError
        false
      end
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :csv_file, :pdf_file, :col_sep, :account_id)
    end

    def handle_statement_upload
      if params.dig(:import, :retry).present?
        password = params.dig(:import, :pdf_password)
        @import.retry_extraction(password: password)
        redirect_to import_upload_path(@import), notice: "Retrying statement analysis..."
        return
      end

      file = upload_params[:pdf_file]

      unless file.present?
        flash.now[:alert] = "Please upload a PDF file"
        render :show, status: :unprocessable_entity
        return
      end

      if file.size > StatementImport::MAX_PDF_SIZE
        flash.now[:alert] = "File is too large. Maximum size is #{StatementImport::MAX_PDF_SIZE / 1.megabyte}MB."
        render :show, status: :unprocessable_entity
        return
      end

      unless StatementImport::ALLOWED_PDF_TYPES.include?(file.content_type)
        flash.now[:alert] = "Invalid file type. Please upload a PDF file."
        render :show, status: :unprocessable_entity
        return
      end

      @import.source_file.attach(file)
      @import.parse_later
      redirect_to import_upload_path(@import), notice: "PDF uploaded. Analyzing your statement..."
    end
end
