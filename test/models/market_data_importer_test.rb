require "test_helper"
require "ostruct"

# TODO: Fix mock setup - tests stub :twelve_data but provider registry now tries :yahoo_finance first.
#       Need to update mocks to match current provider fallback order.
class MarketDataImporterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # SNAPSHOT_START_DATE       = MarketDataImporter::SNAPSHOT_DAYS.days.ago.to_date
  # SECURITY_PRICE_BUFFER     = Security::Price::Importer::PROVISIONAL_LOOKBACK_DAYS.days
  # EXCHANGE_RATE_BUFFER      = 5.days

  # setup do
  #   Security::Price.delete_all
  #   ExchangeRate.delete_all
  #   Trade.delete_all
  #   Holding.delete_all
  #   Security.delete_all
  #
  #   @provider = mock("provider")
  #   Provider::Registry.any_instance
  #                     .stubs(:get_provider)
  #                     .with(:twelve_data)
  #                     .returns(@provider)
  # end

  # test "syncs required exchange rates" do
  # end

  # test "syncs security prices" do
  # end
end
