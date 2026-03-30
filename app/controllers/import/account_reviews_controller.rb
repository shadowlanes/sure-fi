class Import::AccountReviewsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    unless @import.is_a?(StatementImport) && @import.configured?
      redirect_to import_upload_path(@import)
      return
    end

    if @import.account_confirmed?
      redirect_to import_clean_path(@import)
      return
    end

    @matching_accounts = @import.find_matching_accounts
  end

  def update
    account_action = params.dig(:import, :account_action)

    case account_action
    when "existing"
      account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
      unless account
        flash.now[:alert] = "Please select an account."
        @matching_accounts = @import.find_matching_accounts
        render :show, status: :unprocessable_entity
        return
      end
      @import.update!(account: account)

    when "create"
      account = create_detected_account
      @import.update!(account: account)

    else
      flash.now[:alert] = "Please select an account or create a new one."
      @matching_accounts = @import.find_matching_accounts
      render :show, status: :unprocessable_entity
      return
    end

    redirect_to import_clean_path(@import), notice: "Account selected. Review your transactions."
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def create_detected_account
      name = build_account_name
      currency = @import.detected_currency || Current.family.currency
      accountable_type = @import.detected_accountable_type

      accountable = accountable_type.constantize.new
      account = Current.family.accounts.create!(
        name: name,
        currency: currency,
        balance: 0,
        accountable: accountable
      )
      account
    end

    def build_account_name
      parts = []
      parts << @import.detected_account_name if @import.detected_account_name.present?
      parts << @import.detected_account_type&.titleize if @import.detected_account_type.present?
      parts << @import.detected_currency if @import.detected_currency.present?
      name = parts.join(" ")
      name.presence || "Imported Account"
    end
end
